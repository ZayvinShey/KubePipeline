#!/bin/bash
#echo "此脚本只适用于Ubuntu  Centos或者其他Linux发行版需修改成对应的软件包管理器"
echo "！！！截至2024/8/21为止docker全面被墙 本脚本需提前配置代理并修改脚本中配置代理的命令 否则docker将安装不上导致脚本卡死！！！"
sleep 2s
echo "Warning [ 未修改请马上退出安装 已修改则可以无视本警告5秒之后自动开始安装 ]"
sleep 5s
set -e  # 任何命令失败时停止执行
set -u  # 使用未初始化变量时停止执行

echo "
 _____                       _ _ _               _     _             _                 
(_____)            _        | | (_)             | |   | |           | |                
  | |   ____   ___| |_  ____| | |_ ____   ____  | |__ | | ____  ____| | _   ___   ____ 
  | | |  _ \ /___)  _)/ _  | | | |  _ \ / _  |  |  __)| |/ _  |/ ___) || \ / _ \ / ___)
 _| |_| | | |___ | |_( ( | | | | | | | ( ( | |  | |   | ( ( | | |   | |_) ) |_| | |    
(_____)_| |_(___/ \___)_||_|_|_|_|_| |_|\_|| |  |_|   |_|\_||_|_|   |____/ \___/|_|    
                                       (_____|                                         
"
# 设置变量
HARBOR_DIR="/usr/local/src/harbor"                      # harbor根目录
HARBOR_CERTS_DIR="${HARBOR_DIR}/certs"                  # 证书目录
HARBOR_YAML="${HARBOR_DIR}/harbor.yml"                  # harbor配置文件
DOCKER_CERTS_DIR="/etc/docker/certs.d/192.168.200.100/" # docker 证书目录
#添加代理

if ! grep -q "export http_proxy=http://192.168.1.3:7899" /etc/environment; then
    echo "export http_proxy=http://192.168.1.3:7899" | sudo tee -a /etc/environment
fi

if ! grep -q "export https_proxy=http://192.168.1.3:7899" /etc/environment; then
    echo "export https_proxy=http://192.168.1.3:7899" | sudo tee -a /etc/environment
fi
source /etc/environment

# 检查是否有权限执行脚本
if [ "$(id -u)" != "0" ]; then
    echo "Error: This script must be run as root" >&2
    exit 1
fi

# 添加Docker官方GPG密钥
apt-get update
apt-get install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
#下面安装docker需要提前添加代理 上述代理只需修改IP和端口

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc 
chmod a+r /etc/apt/keyrings/docker.asc

# 将存储库添加到 Apt 源
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update

# 安装docker docker-compose
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin  
#新版docker淘汰docker-compose 新版使用docker compose 语法一致命令修改请注意

# 启动docker服务 

systemctl start docker
systemctl enable docker
# sudo systemctl status docker 会导致脚本卡住 需要人为干预

# 下载 Harbor
#wget https://github.com/goharbor/harbor/releases/download/v2.10.2/harbor-offline-installer-v2.10.2.tgz  Github难以下载本机已上传
# 解压 Harbor 安装包
tar xf harbor-offline-installer-v2.10.2.tgz -C /usr/local/src/

# 创建证书目录
mkdir -p "${HARBOR_CERTS_DIR}"
cd "${HARBOR_CERTS_DIR}"

# 生成 CA 证书
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -sha512 -days 3650 \
        -subj "/C=CN/ST=Beijing/L=Beijing/O=example/OU=Personal/CN=192.168.200.100" \
        -key "${HARBOR_CERTS_DIR}/ca.key" \
        -out "${HARBOR_CERTS_DIR}/ca.crt"

# 生成服务器证书
openssl genrsa -out myharbor.key 4096
openssl req -sha512 -new \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=example/OU=Personal/CN=192.168.200.100" \
    -key "${HARBOR_CERTS_DIR}/myharbor.key" \
    -out "${HARBOR_CERTS_DIR}/myharbor.csr"
cat > v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
IP.1=192.168.200.100
EOF
openssl x509 -req -sha512 -days 3650 \
    -extfile "${HARBOR_CERTS_DIR}/v3.ext" \
    -CA "${HARBOR_CERTS_DIR}/ca.crt" -CAkey "${HARBOR_CERTS_DIR}/ca.key" -CAcreateserial \
    -in "${HARBOR_CERTS_DIR}/myharbor.csr" \
    -out "${HARBOR_CERTS_DIR}/myharbor.crt"
openssl x509 -inform PEM -in "${HARBOR_CERTS_DIR}/myharbor.crt" -out "${HARBOR_CERTS_DIR}/harbor.cert"

# 创建 harbor 配置文件
cp "${HARBOR_DIR}/harbor.yml.tmpl" "${HARBOR_YAML}"
# 更新 harbor 配置文件中的主机名和证书路径
sed -i "s/hostname: reg.mydomain.com/hostname: 192.168.200.100/g" "${HARBOR_YAML}"
sed -i "s|certificate: /your/certificate/path|certificate: ${HARBOR_CERTS_DIR}/myharbor.crt|g" "${HARBOR_YAML}"
sed -i "s|private_key: /your/private/key/path|private_key: ${HARBOR_CERTS_DIR}/myharbor.key|g" "${HARBOR_YAML}"

# 添加 docker 证书
mkdir -p ${DOCKER_CERTS_DIR}
#cp "${HARBOR_CERTS_DIR}/harbor.cert" "${DOCKER_CERTS_DIR}"
#cp "${HARBOR_CERTS_DIR}/myharbor.key" "${DOCKER_CERTS_DIR}"
#cp "${HARBOR_CERTS_DIR}/ca.crt" "${DOCKER_CERTS_DIR}"
cp "${HARBOR_CERTS_DIR}/myharbor.crt"  "${DOCKER_CERTS_DIR}"  

# harbor官方文档里需要CERT(服务器证书) KEY(服务器私钥) CRT(CA证书) 三个文件 实测只需要CA证书 不然docker找不到证书就登录不了仓库

# 重启 Docker
systemctl restart docker

# 安装 Harbor
"${HARBOR_DIR}/install.sh" --with-trivy

# 查看 docker-compose 
docker compose -f ${HARBOR_DIR}/docker-compose.yml ps 

# 服务已经启用 浏览器访问 192.168.200.100 即可跳转到harbor仓库登录界面 用户名admin 密码 Harbor12345
echo "---------------------------------------------------------"
echo "harbor根目录在/usr/local/src/harbor"
echo "若是服务器关机后服务将被一同关闭 下次启动请执行启动命令："
echo "sudo docker compose -f /usr/local/src/harbor/docker-compose.yml up -d"
echo "Http服务已启用 可视化界面请浏览器访问 https://192.168.200.100 "
echo "docker登陆测试 用户名admin 密码 Harbor12345"
# docker 登录
docker login 192.168.200.100 #会弹出harbor登录 用户名密码同上

# By ZhangYuShi 2024-4-15
#Update by ZhangYuShi 2024-8-21亲测可以执行
# 后续重启docker或者重启服务器可能会导致harbor服务退出 需回到harbor根目录执行 sudo docker-compose -f docker-compose.yaml up -d 
# 参考文档 https://goharbor.io/docs/2.10.0/install-config/download-installer/
# 参考文档 https://goharbor.io/docs/2.10.0/install-config/configure-https/
# 参考文档 https://docs.docker.com/engine/install/ubuntu/