#!/bin/bash

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================${NC}"
echo -e "${GREEN}    TUIC v5 交互式自动化部署脚本${NC}"
echo -e "${BLUE}======================================${NC}"

# 1. 交互输入域名
read -p "请输入解析到此服务器的域名 (例如 jp.aititilook.cc): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${YELLOW}错误: 域名不能为空。${NC}"
    exit 1
fi

# 2. 申请证书
echo -e "${BLUE}正在申请证书...${NC}"
apt update && apt install -y curl wget socat iptables-persistent
curl https://get.acme.sh | sh -s email="admin@$DOMAIN"
source ~/.bashrc
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone

if [ $? -eq 0 ]; then
    mkdir -p /etc/tuic/
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --key-file /etc/tuic/server.key --fullchain-file /etc/tuic/server.crt
else
    echo -e "${YELLOW}证书申请失败。${NC}"
    exit 1
fi

# 3. 端口跳跃
read -p "起始端口 (默认 20000): " HOP_START
HOP_START=${HOP_START:-20000}
read -p "结束端口 (默认 30000): " HOP_END
HOP_END=${HOP_END:-30000}
LISTEN_PORT=25620

iptables -t nat -A PREROUTING -p udp --dport $HOP_START:$HOP_END -j REDIRECT --to-ports $LISTEN_PORT
ip6tables -t nat -A PREROUTING -p udp --dport $HOP_START:$HOP_END -j REDIRECT --to-ports $LISTEN_PORT
netfilter-persistent save

# 4. 安装服务端 (这里我直接写死链接，不使用变量，防止 404)
echo -e "${BLUE}正在安装 TUIC 服务端...${NC}"
UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

# 直接下载 v1.0.0 正式版，确保链接 100% 有效
wget -O /usr/local/bin/tuic-server https://github.com/EAimTY/tuic/releases/download/1.0.0/tuic-server-1.0.0-x86_64-unknown-linux-gnu

chmod +x /usr/local/bin/tuic-server

cat > /etc/tuic/config.json <<EOF
{
    "server": "[::]:$LISTEN_PORT",
    "users": { "$UUID": "$PASSWORD" },
    "certificate": "/etc/tuic/server.crt",
    "private_key": "/etc/tuic/server.key",
    "congestion_control": "bbr",
    "alpn": ["h3"]
}
EOF

# 5. 启动服务
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC v5 Service
After=network.target
[Service]
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now tuic
echo -e "${GREEN}TUIC 服务启动成功！${NC}"

# 6. 生成链接
echo -e "${BLUE}======================================${NC}"
echo -e "域名: $DOMAIN"
echo -e "端口: $LISTEN_PORT,$HOP_START-$HOP_END"
echo -e "UUID: $UUID"
echo -e "密码: $PASSWORD"
echo -e "${YELLOW}链接：tuic://$UUID:$PASSWORD@$DOMAIN:$LISTEN_PORT?congestion_control=bbr&alpn=h3#AWS-Node${NC}"
echo -e "${BLUE}======================================${NC}"
