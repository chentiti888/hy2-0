#!/bin/bash

# ====================================================
# Project: Hysteria 2 全自动一键安装脚本 (无错增强版)
# Author: Gemini
# Supported OS: Ubuntu 20.04+, Debian 10+
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 脚本运行权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 用户运行此脚本！${NC}" && exit 1

# 环境准备
prepare_env() {
    echo -e "${YELLOW}正在更新系统并安装基础组件...${PLAIN}"
    apt update -y && apt install -y curl wget tar coreutils openssl iptables-persistent socat jq
    
    # 开启内核转发
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
        sysctl -p
    fi
}

# 安装 Hysteria 2
install_hy2() {
    echo -e "${YELLOW}正在获取 Hysteria 2 最新版本...${PLAIN}"
    # 自动获取最新版本号
    last_version=$(curl -Ls "https://api.github.com/repos/apernet/hysteria/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$last_version" ]]; then
        echo -e "${RED}错误：无法获取最新版本号，请检查网络。${PLAIN}"
        exit 1
    fi
    
    echo -e "${GREEN}检测到最新版本：${last_version}${PLAIN}"
    wget -N https://github.com/apernet/hysteria/releases/download/${last_version}/hysteria-linux-amd64 -O /usr/local/bin/hy2
    chmod +x /usr/local/bin/hy2
}

# 配置交互
configure() {
    echo -e "${GREEN}请输入配置信息：${PLAIN}"
    read -p "1. 请输入解析到此服务器的域名: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then echo -e "${RED}错误：域名不能为空${PLAIN}"; exit 1; fi

    read -p "2. 请输入连接密码 (默认随机): " PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -base64 12)

    read -p "3. 请输入主要监听端口 (默认 443): " MAIN_PORT
    [[ -z "$MAIN_PORT" ]] && MAIN_PORT=443

    read -p "4. 请输入端口跳跃范围 (例如 20000:50000, 留空则不开启): " PORT_HOP
    read -p "5. 请输入混淆密码 (留空则不开启): " OBFS_PASS

    # 生成配置文件
    mkdir -p /etc/hy2/
    cat <<EOF > /etc/hy2/config.yaml
listen: :$MAIN_PORT

acme:
  domains:
    - $DOMAIN
  email: admin@$DOMAIN

auth:
  type: password
  password: $PASSWORD

$( [[ -n "$OBFS_PASS" ]] && echo "obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS" )

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
}

# 设置防火墙与服务
setup_service() {
    # 端口跳跃规则 (使用冒号分隔格式)
    if [[ -n "$PORT_HOP" ]]; then
        # 兼容横杠转冒号
        HOP_RANGE=${PORT_HOP//-/:}
        iptables -t nat -A PREROUTING -p udp --dport $HOP_RANGE -j DNAT --to-destination :$MAIN_PORT
        ip6tables -t nat -A PREROUTING -p udp --dport $HOP_RANGE -j DNAT --to-destination :$MAIN_PORT
        # 保存 iptables
        netfilter-persistent save
    fi

    # 写入 Systemd 服务
    cat <<EOF > /etc/systemd/system/hy2.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hy2
ExecStart=/usr/local/bin/hy2 server -c /etc/hy2/config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hy2
    systemctl restart hy2
}

# 输出结果
show_result() {
    echo -e "\n${GREEN}======================================"
    echo -e "Hysteria 2 安装成功！"
    echo -e "======================================"
    
    # 拼接 URL
    URL="hysteria2://$PASSWORD@$DOMAIN:$MAIN_PORT?"
    [[ -n "$OBFS_PASS" ]] && URL="${URL}obfs=salamander&obfs-password=$OBFS_PASS&"
    [[ -n "$PORT_HOP" ]] && URL="${URL}mport=${PORT_HOP//:/,}&"
    URL="${URL}sni=$DOMAIN#Hy2-$DOMAIN"

    echo -e "${WHITE}域名: ${DOMAIN}"
    echo -e "主端口: ${MAIN_PORT}"
    echo -p "密码: ${PASSWORD}"
    [[ -n "$OBFS_PASS" ]] && echo -e "混淆密码: ${OBFS_PASS}"
    [[ -n "$PORT_HOP" ]] && echo -e "跳跃端口: ${PORT_HOP}"
    echo -e "--------------------------------------"
    echo -e "${YELLOW}通用节点地址 (直接复制导入):"
    echo -e "${GREEN}${URL}${PLAIN}"
    echo -e "======================================${PLAIN}"
}

# 执行流程
prepare_env
install_hy2
configure
setup_service
show_result
