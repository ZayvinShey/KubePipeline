#!/bin/bash

set -e  # 任何命令失败时停止执行
set -u  # 使用未初始化变量时停止执行

echo """
╭╮╭━┳━━━┳━━━╮╭━━━┳╮╱╱╭━━━┳╮╱╱╭┳━━━╮
┃┃┃╭┫╭━╮┃╭━╮┃┃╭━╮┃┃╱╱┃╭━╮┃╰╮╭╯┃╭━━╯
┃╰╯╯┃╰━╯┃╰━━╮┃╰━━┫┃╱╱┃┃╱┃┣╮┃┃╭┫╰━━╮
┃╭╮┃┃╭━╮┣━━╮┃╰━━╮┃┃╱╭┫╰━╯┃┃╰╯┃┃╭━━╯
┃┃┃╰┫╰━╯┃╰━╯┃┃╰━╯┃╰━╯┃╭━╮┃╰╮╭╯┃╰━━╮
╰╯╰━┻━━━┻━━━╯╰━━━┻━━━┻╯╱╰╯╱╰╯╱╰━━━╯
"""


# 添加代理
if ! grep -q "http_proxy=http://192.168.1.3:7899" /etc/environment; then
    echo "http_proxy=http://192.168.1.3:7899" | sudo tee -a /etc/environment
fi

if ! grep -q "https_proxy=http://192.168.1.3:7899" /etc/environment; then
    echo "https_proxy=http://192.168.1.3:7899" | sudo tee -a /etc/environment
fi

if ! grep -q "no_proxy=localhost,127.0.0.1,192.168.200.10,192.168.200.20,192.168.200.30" /etc/environment; then
    echo "no_proxy=localhost,127.0.0.1,192.168.200.10,192.168.200.20,192.168.200.30" | sudo tee -a /etc/environment
fi

# 立即生效代理
export http_proxy=http://192.168.1.3:7899
export https_proxy=http://192.168.1.3:7899
export no_proxy=localhost,127.0.0.1,192.168.200.10,192.168.200.20,192.168.200.30

# 关闭防火墙
sudo systemctl disable --now ufw

# 设定主机名
sudo hostnamectl set-hostname k8s-slave-node1

# 更新 /etc/hosts 文件
cat <<EOF | sudo tee -a /etc/hosts
#kubernetes cluster ip
192.168.200.10 k8s-master-node
192.168.200.20 k8s-slave-node1
192.168.200.30 k8s-slave-node2
EOFk

# 配置时间同步
sudo timedatectl set-timezone Asia/Shanghai
sudo apt update
apt install -y ntpdate
ntpdate time1.aliyun.com

# 配置计划任务进行时间同步
(crontab -l 2>/dev/null; echo "0 0 * * * chronyc -a makestep") | sudo crontab -

# 配置内核转发及网桥过滤
echo "Configuring kernel modules and sysctl..."
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

# 注释掉 /etc/fstab 中的 swap 行
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

sudo mkdir -p /etc/sysconfig
echo 'KUBELET_EXTRA_ARGS="--cgroup-driver=systemd"' | sudo tee /etc/sysconfig/kubelet
sudo systemctl enable kubelet

# 禁用代理设置 (Kubernetes相关)
unset http_proxy
unset https_proxy
unset no_proxy

# 创建解压目录
mkdir -p "/home/zayvinshey/extracted_images"

EXTRACT_PATH=/home/zayvinshey/extracted_images

# 解压 images.tar
tar -xf images.tar -C "$EXTRACT_PATH" 

# 导入每个镜像
for image_tar in "$EXTRACT_PATH"/images/*.tar; do
    sudo ctr -n k8s.io images import "$image_tar"
done

#删除kubernetes master节点缓存文件
sudo rm -rf /etc/kubernetes

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

echo "请将master节点的加入集群命令复制到本节点使用root权限执行"
