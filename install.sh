#!/bin/bash

# --- 环境变量与配置 ---
DOMAIN=$1
EMAIL="admin@$DOMAIN"
UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
LISTEN_PORT=25620
HOP_START=20000
HOP_END=30000

if [ -z "$DOMAIN" ]; then
    echo "使用方法: ./tuic_setup.sh <你的域名>"
    exit 1
fi

echo "开始部署 TUIC v5 节点..."

# 1. 系统准备与依赖安装
apt update && apt install -y curl wget socat iptables-persistent htop

# 2. 申请 TLS 证书 (使用 acme.sh)
curl https://get.acme.sh | sh -s email=$EMAIL
source ~/.bashrc
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone
mkdir -p /etc/tuic/
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
    --key-file /etc/tuic/server.key \
    --fullchain-file /etc/tuic/server.crt

# 3. 安装 TUIC v5 服务端
ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] && BIN_ARCH="x86_64-linux-gnu" || BIN_ARCH="aarch64-linux-gnu"
TUIC_VER=$(curl -s https://api.github.com/repos/EAimTY/tuic/releases/latest | grep tag_name | cut -d '"' -f 4)
wget -O /usr/local/bin/tuic-server https://github.com/EAimTY/tuic/releases/download/$TUIC_VER/tuic-server-$TUIC_VER-$BIN_ARCH
chmod +x /usr/local/bin/tuic-server

# 4. 生成配置文件
cat > /etc/tuic/config.json <<EOF
{
    "server": "[::]:$LISTEN_PORT",
    "users": {
        "$UUID": "$PASSWORD"
    },
    "certificate": "/etc/tuic/server.crt",
    "private_key": "/etc/tuic/server.key",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "max_idle_time": 15000
}
EOF

# 5. 配置端口跳跃 (iptables)
iptables -t nat -A PREROUTING -p udp --dport $HOP_START:$HOP_END -j REDIRECT --to-ports $LISTEN_PORT
ip6tables -t nat -A PREROUTING -p udp --dport $HOP_START:$HOP_END -j REDIRECT --to-ports $LISTEN_PORT
netfilter-persistent save

# 6. 配置 Systemd 服务
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC v5 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tuic

# 7. 生成配置信息与链接
echo "--------------------------------------------------"
echo "TUIC v5 部署成功！"
echo "域名: $DOMAIN"
echo "端口: $LISTEN_PORT (跳跃范围: $HOP_START-$HOP_END)"
echo "UUID: $UUID"
echo "密码: $PASSWORD"
echo "--------------------------------------------------"
echo "Shadowrocket 导入链接 (请根据需要调整端口范围):"
echo "tuic://$UUID:$PASSWORD@$DOMAIN:$LISTEN_PORT?congestion_control=bbr&alpn=h3#AWS-TUIC-Node"






    

