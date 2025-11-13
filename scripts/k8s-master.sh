#!/bin/bash

set -e  # 任何命令失败时停止执行
set -u  # 使用未初始化变量时停止执行

echo """
╭╮╭━┳━━━┳━━━╮╭━━━╮
┃┃┃╭┫╭━╮┃╭━╮┃┃╭━╮┃
┃╰╯╯┃╰━╯┃╰━━╮┃╰━╯┣╮╭┳━╮╭━╮╭┳━╮╭━━╮
┃╭╮┃┃╭━╮┣━━╮┃┃╭╮╭┫┃┃┃╭╮┫╭╮╋┫╭╮┫╭╮┃
┃┃┃╰┫╰━╯┃╰━╯┃┃┃┃╰┫╰╯┃┃┃┃┃┃┃┃┃┃┃╰╯┃
╰╯╰━┻━━━┻━━━╯╰╯╰━┻━━┻╯╰┻╯╰┻┻╯╰┻━╮┃
╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╭━╯┃
╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╰━━╯
"""
# 用户名
KUBE_USER="zayvinshey"

# 添加代理
if ! grep -q "http_proxy=http://192.168.1.3:7899" /etc/environment; then
    echo "http_proxy=http://192.168.1.3:7899" | sudo tee -a /etc/environment
fi

if ! grep -q "https_proxy=http://192.168.1.3:7899" /etc/environment; then
    echo "https_proxy=http://192.168.1.3:7899" | sudo tee -a /etc/environment
fi

if ! grep -q "no_proxy=localhost,127.0.0.1,192.168.200.10,192.168.200.20,192.168.200.30,10.96.0.0/12,10.244.0.0/16" /etc/environment; then
    echo "no_proxy=localhost,127.0.0.1,192.168.200.10,192.168.200.20,192.168.200.30,10.96.0.0/12,10.244.0.0/16" | sudo tee -a /etc/environment
fi

# 立即生效代理
export http_proxy=http://192.168.1.3:7899
export https_proxy=http://192.168.1.3:7899
export no_proxy="localhost,127.0.0.1,192.168.200.10,192.168.200.20,192.168.200.30,10.96.0.0/12,10.244.0.0/16"

# 关闭防火墙
sudo systemctl disable --now ufw

# 设定主机名
sudo hostnamectl set-hostname k8s-master-node

# 更新 /etc/hosts 文件
cat <<EOF | sudo tee -a /etc/hosts
# Kubernetes cluster IPs
192.168.200.10 k8s-master-node
192.168.200.20 k8s-slave-node1
192.168.200.30 k8s-slave-node2
EOF

# 配置时间同步
sudo timedatectl set-timezone Asia/Shanghai
sudo apt update
sudo apt install -y ntpdate
sudo ntpdate time1.aliyun.com

# 配置计划任务进行时间同步
(crontab -l 2>/dev/null; echo "0 0 * * * chronyc -a makestep") | sudo crontab -

# 配置内核转发及网桥过滤
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl -p /etc/sysctl.d/k8s.conf
sudo sysctl --system

# 安装 ipset 和 ipvsadm
sudo apt install -y ipset ipvsadm

# 配置 ipvsadm 模块
cat <<EOF | sudo tee /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

sudo modprobe -- ip_vs
sudo modprobe -- ip_vs_rr
sudo modprobe -- ip_vs_wrr
sudo modprobe -- ip_vs_sh
sudo modprobe -- nf_conntrack

# 关闭 SWAP 分区
sudo swapoff -a
sudo sed -i '/swap.img/s/^/#/' /etc/fstab

# 设定 containerd 版本
CONTAINERD_VERSION="1.7.16"

# 下载指定版本的 containerd
sudo wget https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/cri-containerd-$CONTAINERD_VERSION-linux-amd64.tar.gz
sudo tar xf cri-containerd-$CONTAINERD_VERSION-linux-amd64.tar.gz -C /

# 验证 containerd 和 runc 是否安装成功
which containerd
which runc
containerd --version
runc --version

# 创建配置文件目录
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# 修改配置文件
sudo sed -i 's/sandbox_image = "registry.k8s.io\/pause:3.8"/sandbox_image = "registry.aliyuncs.com\/google_containers\/pause:3.9"/' /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd

# 设置 Kubernetes 阿里云镜像源
curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# 安装 kubeadm, kubelet 和 kubectl 并锁定 Kubernetes 版本
sudo apt-get install -y kubelet=1.30.0-1.1 kubeadm=1.30.0-1.1 kubectl=1.30.0-1.1
sudo apt-mark hold kubelet kubeadm kubectl

# 配置 Kubelet 使用 systemd 作为 cgroup driver
sudo mkdir -p /etc/sysconfig
echo 'KUBELET_EXTRA_ARGS="--cgroup-driver=systemd"' | sudo tee /etc/sysconfig/kubelet
sudo systemctl enable kubelet

# 在执行 Kubernetes 相关命令前清空代理设置
unset http_proxy
unset https_proxy
unset no_proxy

# 生成 kubeadm 配置文件
cat <<EOF | sudo tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: abcdef.0123456789abcdef
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.200.10
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: k8s-master-node
  taints: null
---
apiServer:
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager: {}
dns: {}
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: registry.aliyuncs.com/google_containers
kind: ClusterConfiguration
kubernetesVersion: 1.30.0
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
scheduler: {}
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF

# 拉取镜像
sudo kubeadm config images list --image-repository registry.aliyuncs.com/google_containers
sudo kubeadm config images pull --image-repository registry.aliyuncs.com/google_containers

# 初始化 Kubernetes 集群
sudo kubeadm init --config kubeadm-config.yaml

# 配置 kubectl 使用
mkdir -p /home/$KUBE_USER/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/$KUBE_USER/.kube/config
sudo chmod 666 /home/$KUBE_USER/.kube/config

# Kubernetes 命令补全
su -l $KUBE_USER -c "echo 'source <(kubectl completion bash)' >> /home/$KUBE_USER/.bashrc"
su -l $KUBE_USER -c "source /home/$KUBE_USER/.bashrc"
echo "请在node节点执行加入k8s集群命令，脚本在60s后安装网络插件，命令已经生成在上方"
echo "若没有在脚本安装网络插件时使node节点加入集群将导致node节点加入失败"
sleep 60

# 部署 Calico 网络插件
su $KUBE_USER -c "kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml"
sudo wget https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml
sed -i 's/cidr: 192\.168\.0\.0\/16/cidr: 10.244.0.0\/16/g' custom-resources.yaml
su $KUBE_USER -c "kubectl apply -f custom-resources.yaml"

# 创建解压目录
mkdir -p "/home/zayvinshey/extracted_images"

EXTRACT_PATH=/home/zayvinshey/extracted_images

# 解压 images.tar
tar -xf images.tar -C "$EXTRACT_PATH" 

# 导入每个镜像
for image_tar in "$EXTRACT_PATH"/images/*.tar; do
    sudo ctr -n k8s.io images import "$image_tar"
done

# 恢复系统代理
export http_proxy=http://192.168.1.3:7899
export https_proxy=http://192.168.1.3:7899
export no_proxy="localhost,127.0.0.1,192.168.200.10,192.168.200.20,192.168.200.30"

# 安装 Prometheus
# 安装 curl 和必要工具
sudo apt-get install -y curl wget apt-transport-https

# 安装 Helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# 添加 Prometheus 的 Helm 仓库
sudo helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
sudo helm repo update

# 创建命名空间 monitoring
su $KUBE_USER -c "kubectl create namespace monitoring"

# 安装 Prometheus 和 Grafana
sudo helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --kubeconfig /home/zayvinshey/.kube/config

# 等待 Prometheus 和 Grafana 安装完成
echo "等待 Prometheus 和 Grafana 部署完成"
sleep 60

# 获取 Prometheus 和 Grafana 服务状态
su $KUBE_USER -c "kubectl get svc -n monitoring"

# 暴露 Grafana 的端口以便外部访问（暴露NodePort）
su $KUBE_USER -c "kubectl patch svc prometheus-grafana -n monitoring -p '{\"spec\": {\"type\": \"NodePort\"}}'"

# 获取 Grafana 的默认用户名和密码
GRAFANA_POD=$(su $KUBE_USER -c "kubectl get pods -n monitoring -l 'app.kubernetes.io/name=grafana' -o jsonpath='{.items[0].metadata.name}'")
echo "Grafana 默认用户名: admin"
echo "Grafana 默认密码:" 
su $KUBE_USER -c "kubectl get secret --namespace monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 --decode ; echo"

# 提供 Grafana 访问方式
NODE_PORT=$(su $KUBE_USER -c "kubectl get svc prometheus-grafana -n monitoring -o=jsonpath='{.spec.ports[0].nodePort}'")
NODE_IP=$(su $KUBE_USER -c "kubectl get nodes -o=jsonpath='{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}'")
echo "Grafana 可以通过以下地址访问：http://$NODE_IP:$NODE_PORT"

echo "Prometheus 和 Grafana 已部署完成。可以通过 Grafana 导入 Kubernetes 仪表盘进行集群监控。"

# 添加 Harbor containerd仓库

HARBOR_IP="192.168.200.100"
CERTS_DIR="/etc/containerd/certs.d/$HARBOR_IP"
CA_CERT="ca.crt"
MYHARBOR_CERT="myharbor.crt"

# 创建目录 

sudo mkdir -p "$CERTS_DIR"

# 复制证书到目标目录
sudo cp "$CA_CERT" "$MYHARBOR_CERT" "$CERTS_DIR/"
sudo systemctl restart containerd

# 将CA证书添加到系统CA证书库 以防万一
sudo cp "$CERTS_DIR/$CA_CERT" /usr/local/share/ca-certificates/harbor.crt
sudo update-ca-certificates