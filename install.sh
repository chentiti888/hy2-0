#!/bin/bash

# 颜色定义
RED='\033[031m'
GREEN='\033[032m'
YELLOW='\033[033m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行！\n" && exit 1

# 1. 交互式输入
read -p "请输入你的域名 (确保已解析到此服务器 IP): " domain
read -p "请输入你的 UUID (回车随机生成): " uuid
[[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
read -p "请输入你的密码 (回车随机生成): " password
[[ -z "$password" ]] && password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12)
read -p "请输入主监听端口 (默认 8443): " main_port
[[ -z "$main_port" ]] && main_port=8443
read -p "请输入端口跳跃范围 (例如 20000-30000, 留空不开启): " port_range

# 2. 安装基础组件与 acme.sh
apt update && apt install -y curl wget tar jq openssl cron socat
curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --upgrade --auto-upgrade
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 3. 申请证书
mkdir -p /etc/sing-box/cert
~/.acme.sh/acme.sh --issue -d $domain --standalone
~/.acme.sh/acme.sh --install-cert -d $domain \
    --key-file /etc/sing-box/cert/private.key \
    --fullchain-file /etc/sing-box/cert/fullchain.crt

# 4. 下载并安装 sing-box
# 自动获取最新 amd64 版本[span_1](start_span)[span_1](end_span)
SB_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
wget "https://github.com/SagerNet/sing-box/releases/download/${SB_VERSION}/sing-box-${SB_VERSION#v}-linux-amd64.tar.gz" -O sb.tar.gz
tar -zxvf sb.tar.gz
cp sing-box-*/sing-box /usr/local/bin/
rm -rf sb.tar.gz sing-box-*

# 5. 配置端口跳跃 (iptables)
if [[ -n "$port_range" ]]; then
    iptables -t nat -A PREROUTING -p udp --dport $port_range -j REDIRECT --to-ports $main_port
    ip6tables -t nat -A PREROUTING -p udp --dport $port_range -j REDIRECT --to-ports $main_port
    # 保存规则 (Debian)
    apt install -y iptables-persistent
    netfilter-persistent save
fi

# 6. 生成服务端 config.json[span_2](start_span)[span_2](end_span)
cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $main_port,
      "users": [ { "uuid": "$uuid", "password": "$password" } ],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "certificate_path": "/etc/sing-box/cert/fullchain.crt",
        "key_path": "/etc/sing-box/cert/private.key",
        "alpn": ["h3"]
      },
      "congestion_control": "bbr"
    }
  ]
}
EOF

# 7. 启动服务
systemctl stop sing-box 2>/dev/null
cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box

# 8. 生成客户端导入配置
echo -e "\n${GREEN}--- 服务端部署完成 ---${PLAIN}"
echo -e "${YELLOW}客户端 (sing-box) 配置内容：${PLAIN}"
cat <<EOF
{
  "outbounds": [
    {
      "type": "tuic",
      "tag": "tuic-out",
      "server": "$domain",
      "server_port": $main_port,
      "uuid": "$uuid",
      "password": "$password",
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "alpn": ["h3"]
      },
      "congestion_control": "bbr",
      "udp_relay_mode": "quic",
      "hop_interval": "30s"
    }
  ]
}
EOF
[[ -n "$port_range" ]] && echo -e "${RED}注意：请在客户端 server_port 处修改或开启端口跳跃配置${PLAIN}"
