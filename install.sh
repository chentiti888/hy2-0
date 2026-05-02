#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

echo -e "${GREEN}=== TUIC v5 + sing-box 增强版脚本 (官方源修复版) ===${PLAIN}"

# 1. 强制环境初始化
echo -e "${YELLOW}正在初始化系统环境...${PLAIN}"
apt update
apt install -y curl wget jq cron socat iptables iptables-persistent

# 创建必要的配置目录
mkdir -p /etc/sing-box

# 2. 获取用户输入
read -p "请输入解析到此服务器的域名: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}错误: 域名不能为空${PLAIN}"
    exit 1
fi

read -p "请设置 UUID (直接回车随机生成): " UUID
[[ -z "$UUID" ]] && UUID=$(cat /proc/sys/kernel/random/uuid)

read -p "请设置密码 (直接回车随机生成): " PASSWORD
[[ -z "$PASSWORD" ]] && PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)

read -p "请输入主端口 (默认 443): " PORT
PORT=${PORT:-443}

read -p "请输入端口跳跃范围 (例如 20000-30000): " HOP_RANGE

# 3. 申请证书 (Acme.sh)
echo -e "${YELLOW}正在申请证书...${PLAIN}"
if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
    curl https://get.acme.sh | sh
fi
~/.acme.sh/acme.sh --upgrade --auto-upgrade
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone

# 检查证书是否申请成功并安装
if [ -d "$HOME/.acme.sh/${DOMAIN}_ecc" ]; then
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file /etc/sing-box/cert.key \
        --fullchain-file /etc/sing-box/cert.pem
else
    echo -e "${RED}证书申请失败，请检查 80 端口是否放行或域名解析是否正确。${PLAIN}"
    exit 1
fi

# 4. 移植自“八合一”脚本的 Sing-box 安装逻辑
echo -e "${YELLOW}正在通过 GitHub API 获取最新稳定版 Sing-box...${PLAIN}"

# 4.1 获取最新正式版版本号[span_2](start_span)[span_2](end_span)
SB_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases | \
    jq -r '[.[] | select(.prerelease==false)][0].tag_name' | sed 's/v//g')

if [ -z "$SB_VERSION" ]; then
    echo -e "${RED}错误: 无法获取 Sing-box 版本，请检查网络连接。${PLAIN}"
    exit 1
fi

# 4.2 架构识别[span_3](start_span)[span_3](end_span)
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  SB_ARCH="linux-amd64" ;;
    aarch64) SB_ARCH="linux-arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

# 4.3 拼接下载地址并下载[span_4](start_span)[span_4](end_span)
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-${SB_ARCH}.tar.gz"
echo -e "${BLUE}正在下载版本: v${SB_VERSION} ($SB_ARCH)...${PLAIN}"

cd /etc/sing-box
curl -L -O "${DOWNLOAD_URL}"
tar -zxvf "sing-box-${SB_VERSION}-${SB_ARCH}.tar.gz"

# 4.4 部署二进制程序并清理[span_5](start_span)[span_5](end_span)
mv "sing-box-${SB_VERSION}-${SB_ARCH}/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf "sing-box-${SB_VERSION}-${SB_ARCH}.tar.gz" "sing-box-${SB_VERSION}-${SB_ARCH}"

# 5. 配置端口跳跃 (iptables)
if [[ -n "$HOP_RANGE" ]]; then
    echo -e "${YELLOW}配置端口跳跃规则: $HOP_RANGE -> $PORT${PLAIN}"
    iptables -t nat -A PREROUTING -p udp --dport $HOP_RANGE -j REDIRECT --to-ports $PORT
    ip6tables -t nat -A PREROUTING -p udp --dport $HOP_RANGE -j REDIRECT --to-ports $PORT
    netfilter-persistent save
fi

# 6. 写入配置文件
cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [ { "uuid": "$UUID", "password": "$PASSWORD" } ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/cert.key",
        "alpn": [ "h3" ]
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

# 7. 配置 Systemd 服务并启动[span_6](start_span)[span_6](end_span)
cat <<SYSTEMD > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box Service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# 8. 输出结果
echo -e "---"
echo -e "${GREEN}部署完成！${PLAIN}"
echo -e "${BLUE}域名:${PLAIN} $DOMAIN"
echo -e "${BLUE}UUID:${PLAIN} $UUID"
echo -e "${BLUE}密码:${PLAIN} $PASSWORD"
echo -e "${BLUE}主端口:${PLAIN} $PORT"

BASE_URL="tuic://$UUID:$PASSWORD@$DOMAIN:$PORT?congestion_control=bbr&alpn=h3&sni=$DOMAIN&udp_relay_mode=native"

if [[ -n "$HOP_RANGE" ]]; then
    echo -e "${BLUE}端口跳跃链接:${PLAIN} tuic://$UUID:$PASSWORD@$DOMAIN:$HOP_RANGE?congestion_control=bbr&alpn=h3&sni=$DOMAIN&udp_relay_mode=native"
else
    echo -e "${BLUE}通用链接:${PLAIN} $BASE_URL"
fi
