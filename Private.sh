#!/usr/bin/env bash

set -e

echo "================================================="
echo " Xray-core VLESS Selective Installer"
echo " 可选安装："
echo " 1. VLESS + XHTTP + REALITY + ENC"
echo " 2. VLESS + XHTTP + TLS + CDN + ENC"
echo " 3. VLESS + WS + TLS + CDN + ENC"
echo "    可选 Cloudflare Tunnel: none / temp / fixed"
echo "================================================="

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

ask_yes_no() {
  local prompt="$1"
  local default="$2"
  local ans
  read -p "$prompt [$default]: " ans
  ans=${ans:-$default}
  case "$ans" in
    y|Y|yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

random_port() {
  shuf -i 20000-50000 -n 1
}

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

INSTALL_REALITY=0
INSTALL_XHTTP_CDN=0
INSTALL_WS_CDN=0

echo ""
echo "请选择需要安装的协议（可多选）"
echo "================================================="
echo "1) VLESS + XHTTP + REALITY + ENC"
echo "2) VLESS + XHTTP + TLS + CDN + ENC"
echo "3) VLESS + WS + TLS + CDN + ENC"
echo "================================================="
echo "输入示例："
echo "1           仅安装协议1"
echo "1 2         安装协议1和2"
echo "1 2 3       安装全部协议"
echo ""

read -p "请输入协议编号: " INSTALL_OPTIONS

for opt in $INSTALL_OPTIONS; do
  case "$opt" in
    1)
      INSTALL_REALITY=1
      ;;
    2)
      INSTALL_XHTTP_CDN=1
      ;;
    3)
      INSTALL_WS_CDN=1
      ;;
  esac
done

if [ "$INSTALL_REALITY" = "0" ] && [ "$INSTALL_XHTTP_CDN" = "0" ] && [ "$INSTALL_WS_CDN" = "0" ]; then
  echo "未选择任何协议，已退出。"
  exit 0
fi

read -p "请输入 UUID，留空自动生成: " UUID
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

ENC="mlkem768x25519"

REALITY_ADDRESS=""
REALITY_PORT=""
REALITY_SNI=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

XHTTP_DOMAIN=""
XHTTP_PATH=""
XHTTP_SOCK="/run/xray-xhttp.sock"

WS_DOMAIN=""
WS_PORT=""
WS_PATH=""

CDN_PREFERRED_MODE=0
CDN_ADDRESS=""
CF_TUNNEL_MODE=0
CF_TUNNEL_HOST=""
CF_TUNNEL_TOKEN=""

if [ "$INSTALL_REALITY" = "1" ]; then
  echo ""
  echo "配置 1) VLESS + XHTTP + REALITY + ENC"
  read -p "请输入 REALITY 连接地址，VPS IP 或域名，留空自动获取公网 IPv4: " REALITY_ADDRESS
  read -p "请输入 REALITY 端口 [默认随机]: " REALITY_PORT
  read -p "请输入 REALITY 伪装域名 [默认 www.cloudflare.com]: " REALITY_SNI
  REALITY_PORT=${REALITY_PORT:-$(random_port)}
  REALITY_SNI=${REALITY_SNI:-www.cloudflare.com}
fi

if [ "$INSTALL_XHTTP_CDN" = "1" ]; then
  echo ""
  echo "配置 2) VLESS + XHTTP + TLS + CDN + ENC"
  read -p "请输入 VLESS+XHTTP+CDN 域名，例如 cdn.example.com: " XHTTP_DOMAIN
  read -p "请输入 XHTTP Path [默认 /xhttp]: " XHTTP_PATH
  XHTTP_PATH=${XHTTP_PATH:-/xhttp}
fi

if [ "$INSTALL_WS_CDN" = "1" ]; then
  echo ""
  echo "配置 3) VLESS + WS + TLS + CDN + ENC"
  read -p "请输入 WS+TLS+CDN 域名，例如 ws.example.com: " WS_DOMAIN
  read -p "请输入 WS 回源/隧道端口 [默认随机]: " WS_PORT
  read -p "请输入 WS Path [默认 /ws]: " WS_PATH
  WS_PORT=${WS_PORT:-$(random_port)}
  WS_PATH=${WS_PATH:-/ws}

  echo ""
  echo "Cloudflare Tunnel 模式："
  echo "0) 不安装 / 不启用 Tunnel"
  echo "1) 临时隧道 trycloudflare.com，适合测试"
  echo "2) 固定隧道 token，适合长期使用"
  read -p "请选择 [默认 0]: " CF_TUNNEL_MODE
  CF_TUNNEL_MODE=${CF_TUNNEL_MODE:-0}

  if [ "$CF_TUNNEL_MODE" = "2" ]; then
    echo ""
    echo "固定隧道说明："
    echo "请先到 Cloudflare Zero Trust -> Networks -> Tunnels -> Create tunnel -> Cloudflared"
    echo "复制系统给你的 token。"
    echo "同时在 Public Hostname 中设置："
    echo "  Hostname: 你的固定隧道域名，例如 tunnel.example.com"
    echo "  Service Type: HTTP"
    echo "  URL: 127.0.0.1:$WS_PORT"
    echo ""
    read -p "请输入固定隧道公网域名，例如 tunnel.example.com: " CF_TUNNEL_HOST
    read -p "请输入 Cloudflare Tunnel Token: " CF_TUNNEL_TOKEN
  fi
fi

if [ "$INSTALL_XHTTP_CDN" = "1" ] || [ "$INSTALL_WS_CDN" = "1" ]; then
  echo ""
  echo "CDN 优选设置："
  echo "0) 不启用优选，客户端直连真实 CDN 域名"
  echo "1) 启用优选域名/IP，默认 www.visa.cn"
  read -p "请选择 [默认 0]: " CDN_PREFERRED_MODE
  CDN_PREFERRED_MODE=${CDN_PREFERRED_MODE:-0}
  if [ "$CDN_PREFERRED_MODE" = "1" ]; then
    read -p "请输入 CDN 优选域名/IP [默认 www.visa.cn]: " CDN_ADDRESS
    CDN_ADDRESS=${CDN_ADDRESS:-www.visa.cn}
  fi
fi

echo ""
echo "安装依赖..."
apt update -y
apt install -y curl unzip socat openssl nginx python3 lsb-release ca-certificates gnupg coreutils

if [ "$INSTALL_REALITY" = "1" ] && [ -z "$REALITY_ADDRESS" ]; then
  REALITY_ADDRESS=$(curl -4s --max-time 5 https://api.ipify.org || true)
  if [ -z "$REALITY_ADDRESS" ]; then
    REALITY_ADDRESS=$(hostname -I | awk '{print $1}')
  fi
fi

echo ""
echo "安装 / 更新 Xray-core..."
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

mkdir -p /usr/local/etc/xray/
mkdir -p /run

INBOUNDS=""

if [ "$INSTALL_REALITY" = "1" ]; then
  echo ""
  echo "生成 REALITY 密钥..."
  KEYS=$(/usr/local/bin/xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
  PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
  SHORT_ID=$(openssl rand -hex 8)

  INBOUNDS="${INBOUNDS}
    {
      \"tag\": \"vless-xhttp-reality-enc\",
      \"listen\": \"0.0.0.0\",
      \"port\": $REALITY_PORT,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"$UUID\",
            \"email\": \"xhttp-reality\"
          }
        ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"$REALITY_SNI:443\",
          \"xver\": 0,
          \"serverNames\": [
            \"$REALITY_SNI\"
          ],
          \"privateKey\": \"$PRIVATE_KEY\",
          \"shortIds\": [
            \"$SHORT_ID\"
          ]
        }
      }
    },"
fi

if [ "$INSTALL_XHTTP_CDN" = "1" ]; then
  INBOUNDS="${INBOUNDS}
    {
      \"tag\": \"vless-xhttp-tls-cdn-enc\",
      \"listen\": \"$XHTTP_SOCK,0666\",
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"$UUID\",
            \"email\": \"xhttp-cdn\"
          }
        ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"none\",
        \"xhttpSettings\": {
          \"path\": \"$XHTTP_PATH\"
        }
      }
    },"
fi

if [ "$INSTALL_WS_CDN" = "1" ]; then
  INBOUNDS="${INBOUNDS}
    {
      \"tag\": \"vless-ws-tls-cdn-enc\",
      \"listen\": \"127.0.0.1\",
      \"port\": $WS_PORT,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"$UUID\",
            \"email\": \"ws-cdn\"
          }
        ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"security\": \"none\",
        \"wsSettings\": {
          \"path\": \"$WS_PATH\"
        }
      }
    },"
fi

# remove trailing comma
INBOUNDS=$(echo "$INBOUNDS" | sed '$ s/,$//')

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
$INBOUNDS
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

if [ "$INSTALL_XHTTP_CDN" = "1" ] || [ "$INSTALL_WS_CDN" = "1" ]; then
  echo ""
  echo "配置 Nginx 反代 CDN..."
  mkdir -p /etc/nginx/conf.d/
  mkdir -p /etc/ssl/xray/

  CERT_DOMAIN="$XHTTP_DOMAIN"
  if [ -z "$CERT_DOMAIN" ]; then
    CERT_DOMAIN="$WS_DOMAIN"
  fi

  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout /etc/ssl/xray/cdn.key \
    -out /etc/ssl/xray/cdn.crt \
    -subj "/CN=$CERT_DOMAIN"

  SERVER_NAMES=""
  if [ "$INSTALL_XHTTP_CDN" = "1" ]; then
    SERVER_NAMES="$SERVER_NAMES $XHTTP_DOMAIN"
  fi
  if [ "$INSTALL_WS_CDN" = "1" ]; then
    SERVER_NAMES="$SERVER_NAMES $WS_DOMAIN"
  fi

  LOCATIONS=""

  if [ "$INSTALL_XHTTP_CDN" = "1" ]; then
    LOCATIONS="${LOCATIONS}
    location $XHTTP_PATH {
        proxy_redirect off;
        proxy_pass http://unix:$XHTTP_SOCK:;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
"
  fi

  if [ "$INSTALL_WS_CDN" = "1" ]; then
    LOCATIONS="${LOCATIONS}
    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$WS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
"
  fi

  cat > /etc/nginx/conf.d/xray-cdn.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $SERVER_NAMES;

    ssl_certificate /etc/ssl/xray/cdn.crt;
    ssl_certificate_key /etc/ssl/xray/cdn.key;

$LOCATIONS

    location / {
        return 200 "ok";
        add_header Content-Type text/plain;
    }
}
EOF

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
fi

systemctl enable xray
systemctl restart xray

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    echo "cloudflared 已安装：$(cloudflared --version)"
    return
  fi

  echo ""
  echo "安装 cloudflared..."
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | tee /etc/apt/sources.list.d/cloudflared.list
  apt update -y
  apt install -y cloudflared
}

if [ "$INSTALL_WS_CDN" = "1" ] && [ "$CF_TUNNEL_MODE" = "1" ]; then
  install_cloudflared

  echo ""
  echo "启动 Cloudflare 临时隧道..."
  mkdir -p /var/log/cloudflared
  pkill -f "cloudflared tunnel --url http://127.0.0.1:$WS_PORT" || true
  nohup cloudflared tunnel --url http://127.0.0.1:$WS_PORT > /var/log/cloudflared/quick-tunnel.log 2>&1 &

  sleep 8

  CF_TUNNEL_HOST=$(grep -oE "https://[-a-zA-Z0-9.]+\.trycloudflare\.com" /var/log/cloudflared/quick-tunnel.log | head -n1 | sed 's#https://##')

  if [ -z "$CF_TUNNEL_HOST" ]; then
    echo "未能自动读取 trycloudflare 域名，请查看日志："
    echo "cat /var/log/cloudflared/quick-tunnel.log"
  else
    echo "临时隧道地址：https://$CF_TUNNEL_HOST"
  fi
fi

if [ "$INSTALL_WS_CDN" = "1" ] && [ "$CF_TUNNEL_MODE" = "2" ]; then
  install_cloudflared

  echo ""
  echo "安装 Cloudflare 固定隧道服务..."
  if [ -z "$CF_TUNNEL_TOKEN" ]; then
    echo "未填写 Cloudflare Tunnel Token，跳过固定隧道安装。"
  else
    cloudflared service uninstall >/dev/null 2>&1 || true
    cloudflared service install "$CF_TUNNEL_TOKEN"
    systemctl enable cloudflared
    systemctl restart cloudflared
    echo "固定隧道服务已安装并启动。"
  fi
fi

ENC_URL=$(urlencode "$ENC")

OUTPUT_FILE=~/vless-xray-selective-client.txt
cat > "$OUTPUT_FILE" <<EOF
=================================================
Xray-core VLESS 客户端信息
=================================================
UUID: $UUID
ENC: $ENC

EOF

if [ "$CDN_PREFERRED_MODE" = "1" ]; then
  CDN_PREFERRED_STATUS="启用：$CDN_ADDRESS"
else
  CDN_PREFERRED_STATUS="未启用"
fi

if [ "$INSTALL_REALITY" = "1" ]; then
  REALITY_LINK="vless://${UUID}@${REALITY_ADDRESS}:${REALITY_PORT}?encryption=${ENC_URL}&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp#VLESS-XHTTP-REALITY-ENC"
  cat >> "$OUTPUT_FILE" <<EOF
=================================================
VLESS + XHTTP + REALITY + ENC
=================================================
$REALITY_LINK

REALITY 连接地址: $REALITY_ADDRESS
REALITY 端口: $REALITY_PORT
REALITY SNI: $REALITY_SNI
REALITY PublicKey: $PUBLIC_KEY
REALITY ShortID: $SHORT_ID

EOF
fi

if [ "$INSTALL_XHTTP_CDN" = "1" ]; then
  XHTTP_CLIENT_ADDRESS="$XHTTP_DOMAIN"
  if [ "$CDN_PREFERRED_MODE" = "1" ]; then
    XHTTP_CLIENT_ADDRESS="$CDN_ADDRESS"
  fi
  XHTTP_PATH_URL=$(urlencode "$XHTTP_PATH")
  XHTTP_CDN_LINK="vless://${UUID}@${XHTTP_CLIENT_ADDRESS}:443?encryption=${ENC_URL}&security=tls&type=xhttp&host=${XHTTP_DOMAIN}&path=${XHTTP_PATH_URL}&sni=${XHTTP_DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1#VLESS-XHTTP-TLS-CDN-ENC"
  cat >> "$OUTPUT_FILE" <<EOF
=================================================
VLESS + XHTTP + TLS + CDN + ENC
=================================================
$XHTTP_CDN_LINK

XHTTP CDN 真实域名: $XHTTP_DOMAIN
XHTTP Path: $XHTTP_PATH
CDN 优选状态: $CDN_PREFERRED_STATUS

EOF
fi

if [ "$INSTALL_WS_CDN" = "1" ]; then
  WS_CLIENT_ADDRESS="$WS_DOMAIN"
  if [ "$CDN_PREFERRED_MODE" = "1" ]; then
    WS_CLIENT_ADDRESS="$CDN_ADDRESS"
  fi
  WS_PATH_URL=$(urlencode "$WS_PATH")
  WS_CDN_LINK="vless://${UUID}@${WS_CLIENT_ADDRESS}:443?encryption=${ENC_URL}&security=tls&type=ws&host=${WS_DOMAIN}&path=${WS_PATH_URL}&sni=${WS_DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1#VLESS-WS-TLS-CDN-ENC"

  if [ -n "$CF_TUNNEL_HOST" ]; then
    WS_TUNNEL_LINK="vless://${UUID}@${CF_TUNNEL_HOST}:443?encryption=${ENC_URL}&security=tls&type=ws&host=${CF_TUNNEL_HOST}&path=${WS_PATH_URL}&sni=${CF_TUNNEL_HOST}&fp=chrome&alpn=h2%2Chttp%2F1.1#VLESS-WS-TLS-CF-TUNNEL-ENC"
  else
    WS_TUNNEL_LINK="未生成。若使用固定隧道，请确认 Public Hostname 已指向 http://127.0.0.1:$WS_PORT"
  fi

  cat >> "$OUTPUT_FILE" <<EOF
=================================================
VLESS + WS + TLS + CDN + ENC
=================================================
$WS_CDN_LINK

WS CDN 真实域名: $WS_DOMAIN
WS Path: $WS_PATH
WS 回源/隧道端口: $WS_PORT
CDN 优选状态: $CDN_PREFERRED_STATUS

=================================================
VLESS + WS + TLS + Cloudflare Tunnel + ENC
=================================================
$WS_TUNNEL_LINK

Cloudflare Tunnel Host: $CF_TUNNEL_HOST
Cloudflare Tunnel 回源: http://127.0.0.1:$WS_PORT

EOF
fi

cat >> "$OUTPUT_FILE" <<EOF
=================================================
使用说明
=================================================
1. 客户端请选择 Xray-core 内核，不是 v2fly/v2ray-core。
2. v2rayN 导入链接后，内核请选择 Xray。
3. CDN 协议请将域名开启 Cloudflare 橙云。
4. Cloudflare SSL/TLS 建议选择 Full 或 Full strict。
5. REALITY 协议不要套 CDN，直连 VPS。
6. XHTTP CDN 已使用 Unix Socket，不需要回源端口。
7. WS CDN 保留回源/隧道端口，方便与 Cloudflare Tunnel 对齐。
8. 如果客户端不支持 mlkem768x25519，请把链接里的 encryption=mlkem768x25519 改成 encryption=none。
EOF

echo ""
echo "================================================="
echo " 安装完成，客户端信息如下"
echo "================================================="
cat "$OUTPUT_FILE"
echo ""
echo "客户端信息已保存到：$OUTPUT_FILE"
