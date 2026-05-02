#!/bin/bash

# --- 颜色设置 ---
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
    echo -e "${YELLOW}错误: 域名不能为空，请重新运行脚本。${NC}"
    exit 1
fi

echo -e "${BLUE}已记录域名: $DOMAIN${NC}"
echo -e "${YELLOW}提示: 请确保你已经在 AWS 安全组放行了 TCP 80 端口用于证书申请。${NC}"
read -p "准备好申请 SSL 证书了吗？(按回车继续): "

# 2. 申请证书
echo -e "${BLUE}正在通过 acme.sh 申请证书，请稍候...${NC}"
apt update && apt install -y curl wget socat iptables-persistent
curl https://get.acme.sh | sh -s email="admin@$DOMAIN"
source ~/.bashrc
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone

if [ $? -eq 0 ]; then
    echo -e "${GREEN}恭喜！SSL 证书注册成功。${NC}"
    mkdir -p /etc/tuic/
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file /etc/tuic/server.key \
        --fullchain-file /etc/tuic/server.crt
else
    echo -e "${YELLOW}证书申请失败，请检查 80 端口是否放行或域名解析是否正确。${NC}"
    exit 1
fi

# 3. 端口跳跃设置
echo -e "${BLUE}--------------------------------------${NC}"
echo -e "${YELLOW}现在配置“端口跳跃”以解决断流问题。${NC}"
read -p "请输入起始端口 (默认 20000): " HOP_START
HOP_START=${HOP_START:-20000}
read -p "请输入结束端口 (默认 30000): " HOP_END
HOP_END=${HOP_END:-30000}
LISTEN_PORT=25620

echo -e "${BLUE}正在写入防火墙规则...${NC}"
iptables -t nat -A PREROUTING -p udp --dport $HOP_START:$HOP_END -j REDIRECT --to-ports $LISTEN_PORT
ip6tables -t nat -A PREROUTING -p udp --dport $HOP_START:$HOP_END -j REDIRECT --to-ports $LISTEN_PORT
netfilter-persistent save
echo -e "${GREEN}端口跳跃配置成功！范围: $HOP_START-$HOP_END${NC}"

# 4. 安装服务端 (修复 404 错误部分)
echo -e "${BLUE}正在拉取并安装 TUIC v5 最新服务端...${NC}"
UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
ARCH=$(uname -m)

# 修正架构判定与二进制文件名
if [ "$ARCH" = "x86_64" ]; then
    BIN_ARCH="x86_64-unknown-linux-gnu"
elif [ "$ARCH" = "aarch64" ]; then
    BIN_ARCH="aarch64-unknown-linux-gnu"
else
    BIN_ARCH="x86_64-unknown-linux-gnu"
fi

# 修正下载仓库地址
TUIC_VER=$(curl -s https://api.github.com/repos/EAimTY/tuic/releases/latest | grep tag_name | cut -d '"' -f 4)
wget -O /usr/local/bin/tuic-server https://github.com/EAimTY/tuic/releases/download/$TUIC_VER/tuic-server-$TUIC_VER-$BIN_ARCH
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
echo -e "${GREEN}部署完成！请保存以下信息：${NC}"
echo -e "域名: $DOMAIN"
echo -e "主端口: $LISTEN_PORT"
echo -e "跳跃端口范围: $HOP_START-$HOP_END"
echo -e "UUID: $UUID"
echo -e "密码: $PASSWORD"
echo -e "${BLUE}--------------------------------------${NC}"
echo -e "${YELLOW}Shadowrocket 导入链接：${NC}"
echo -e "tuic://$UUID:$PASSWORD@$DOMAIN:$LISTEN_PORT?congestion_control=bbr&alpn=h3#AWS-Node"
echo -e "${BLUE}======================================${NC}"
