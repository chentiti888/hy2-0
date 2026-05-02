#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

echo -e "${GREEN}=== TUIC v5 + sing-box 一键部署脚本 ===${PLAIN}"

# 1. 基础环境安装
apt update && apt install -y curl wget jq cron socat

# 2. 获取用户输入
read -p "请输入解析到此服务器的域名: " DOMAIN
read -p "请设置 UUID (直接回车随机生成): " UUID
[[ -z "$UUID" ]] && UUID=$(cat /proc/sys/kernel/random/uuid)
read -p "请设置密码 (直接回车随机生成): " PASSWORD
[[ -z "$PASSWORD" ]] && PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
read -p "请输入主端口 (默认 443): " PORT
PORT=${PORT:-443}
read -p "请输入端口跳跃范围 (例如 20000-30000): " HOP_RANGE

# 3. 申请证书 (Acme.sh)
echo -e "${YELLOW}正在申请证书...${PLAIN}"
curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --upgrade --auto-upgrade
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
    --key-file /etc/sing-box/cert.key \
    --fullchain-file /etc/sing-box/cert.pem

# 4. 安装 sing-box
bash <(curl -Ls https://raw.githubusercontent.com/SagerNet/sing-box/main/install.sh)

# 5. 配置端口跳跃 (iptables)
echo -e "${YELLOW}配置端口跳跃规则...${PLAIN}"
IFS='-' read -r START_PORT END_PORT <<< "$HOP_RANGE"
iptables -t nat -A PREROUTING -p udp --dport $HOP_RANGE -j REDIRECT --to-ports $PORT
ip6tables -t nat -A PREROUTING -p udp --dport $HOP_RANGE -j REDIRECT --to-ports $PORT

# 6. 生成 sing-box 配置文件
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

# 7. 启动服务
systemctl enable sing-box
systemctl restart sing-box

# 8. 生成导入链接
# TUIC 格式: tuic://uuid:pass@domain:port?congestion_control=bbr&alpn=h3&sni=domain&udp_relay_mode=native#TUIC_singbox
# 注意：端口跳跃在客户端需填写为 port_hooping 格式
ENCODED_LINK="tuic://$UUID:$PASSWORD@$DOMAIN:$PORT?congestion_control=bbr&alpn=h3&sni=$DOMAIN&udp_relay_mode=native"
HOP_LINK="tuic://$UUID:$PASSWORD@$DOMAIN:$START_PORT-$END_PORT?congestion_control=bbr&alpn=h3&sni=$DOMAIN&udp_relay_mode=native"

echo -e "---"
echo -e "${GREEN}部署完成！${PLAIN}"
echo -e "${BLUE}主端口链接:${PLAIN} $ENCODED_LINK"
echo -e "${BLUE}端口跳跃链接:${PLAIN} $HOP_LINK"
echo -e "${YELLOW}提示: 部分客户端支持 20000-30000 格式的端口范围填写。${PLAIN}"
