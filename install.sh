#!/bin/bash

# --- 颜色设置 ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 修复在管道模式 (wget | bash) 下无法交互的问题
exec 3<&1
exec < /dev/tty

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
echo -e "${YELLOW}提示: 请确保你已经在云平台安全组放行了 TCP 80 端口。${NC}"
read -p "准备好申请 SSL 证书了吗？(按回车继续): "

# 2. 申请证书
echo -e "${BLUE}正在通过 acme.sh 申请证书，请稍候...${NC}"
apt update && apt install -y curl wget socat iptables-persistent
curl https://get.acme.sh | sh -s email="admin@$DOMAIN"
# 强制加载 acme.sh 环境
export LE_WORKING_DIR="${HOME}/.acme.sh"
alias acme.sh="${HOME}/.acme.sh/acme.sh"

"${HOME}/.acme.sh/acme.sh" --issue -d "$DOMAIN" --standalone

if [ $? -eq 0 ]; then
    echo -e "${GREEN}恭喜！SSL 证书注册成功。${NC}"
    mkdir -p /etc/tuic/
    "${HOME}/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
        --key-file /etc/tuic/server.key \
        --fullchain-file /etc/tuic/server.crt
else
    echo -e "${YELLOW}证书申请失败，请检查 80 端口是否放行或域名解析是否正确。${NC}"
    exit 1
fi

# 3. 端口跳跃设置
echo -e "${BLUE}--------------------------------------${NC}"
echo -e "${YELLOW}配置“端口跳跃”以解决断流问题。${NC}"
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

# 4. 安装服务端 (修复 404 报错)
echo -e "${BLUE}正在拉取并安装 TUIC v5 最新服务端...${NC}"
UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

# 自动识别架构并匹配 EAimTY 仓库的链接格式
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    BIN_ARCH="x86_64-unknown-linux-gnu"
elif [ "$ARCH" = "aarch64" ]; then
    BIN_ARCH="aarch64-unknown-linux-gnu"
else
    echo -e "${YELLOW}错误: 不支持的架构 $ARCH${NC}"
    exit 1
fi

# 自动获取最新版本号
TUIC_VER=$(curl -s https://api.github.com/repos/EAimTY/tuic/releases/latest | grep tag_name | cut -d '"' -f 4)

# 执行下载
wget -O /usr/local/bin/tuic-server "https://github.com/EAimTY/tuic/releases/download/${TUIC_VER}/tuic-server-${TUIC_VER}-${BIN_ARCH}"

if [ $? -ne 0 ]; then
    echo -e "${YELLOW}错误: 下载 TUIC 服务端失败 (404)，请检查网络或版本。${NC}"
    exit 1
fi

chmod +x /usr/local/bin/tuic-server

# 写入配置文件
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

# 还原输入流
exec <&3
exec 3<&-

# 6. 生成结果
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
echo -e "${YELLOW}提示: 在小火箭中请手动将端口修改为: $LISTEN_PORT,$HOP_START-$HOP_END${NC}"
