#!/usr/bin/env bash
set -e

# =================================================
# Xray-only ArgosBX-style Installer
# Protocol groups:
#   vlpt: VLESS + TCP + REALITY + Vision
#   xhpt: VLESS + XHTTP + REALITY + ENC(auto fallback)
#   vwpt: VLESS + WS + TLS + CDN + ENC(auto fallback)
#   argo: Cloudflare Tunnel, only binds vwpt
# =================================================

echo "================================================="
echo " Xray-core ArgosBX-style VLESS Installer"
echo "================================================="
echo "协议结构："
echo "1) vlpt  VLESS + TCP + REALITY + Vision"
echo "2) xhpt  VLESS + XHTTP + REALITY + ENC"
echo "3) vwpt  VLESS + WS + TLS + CDN + ENC"
echo "4) argo  Cloudflare Tunnel，仅绑定 vwpt"
echo "================================================="

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

random_port() { shuf -i 20000-50000 -n 1; }
urlencode() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

get_public_ip() {
  local ip
  ip=$(curl -4s --max-time 5 https://api.ipify.org || true)
  [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    echo "cloudflared 已安装：$(cloudflared --version)"
    return
  fi
  echo "安装 cloudflared..."
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  apt update -y
  apt install -y cloudflared
}

test_xray_config() {
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/tmp/xray-config-test.log 2>&1
}

write_config() {
  export ENABLE_VLPT ENABLE_XHPT ENABLE_VWPT UUID VLESS_DECRYPTION
  export VLPT_PORT XHPT_PORT VWPT_PORT
  export REALITY_SNI XRAY_PRIVATE_KEY XRAY_SHORT_ID
  export XHPT_PATH VWPT_PATH

python3 <<'PY'
import json, os

uuid = os.environ["UUID"]
decryption = os.environ.get("VLESS_DECRYPTION", "none")
sni = os.environ.get("REALITY_SNI", "www.cloudflare.com")
private_key = os.environ.get("XRAY_PRIVATE_KEY", "")
short_id = os.environ.get("XRAY_SHORT_ID", "")

inbounds = []

if os.environ.get("ENABLE_VLPT") == "1":
    inbounds.append({
        "tag": "vlpt-vless-tcp-reality-vision",
        "listen": "0.0.0.0",
        "port": int(os.environ["VLPT_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": uuid,
                "flow": "xtls-rprx-vision",
                "email": "vlpt"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": f"{sni}:443",
                "xver": 0,
                "serverNames": [sni],
                "privateKey": private_key,
                "shortIds": [short_id]
            }
        }
    })

if os.environ.get("ENABLE_XHPT") == "1":
    inbounds.append({
        "tag": "xhpt-vless-xhttp-reality-enc",
        "listen": "0.0.0.0",
        "port": int(os.environ["XHPT_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": uuid,
                "email": "xhpt"
            }],
            "decryption": decryption
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "reality",
            "xhttpSettings": {
                "path": os.environ.get("XHPT_PATH", "/xhpt"),
                "mode": "auto"
            },
            "realitySettings": {
                "show": False,
                "dest": f"{sni}:443",
                "xver": 0,
                "serverNames": [sni],
                "privateKey": private_key,
                "shortIds": [short_id]
            }
        }
    })

if os.environ.get("ENABLE_VWPT") == "1":
    inbounds.append({
        "tag": "vwpt-vless-ws-cdn-enc",
        "listen": "127.0.0.1",
        "port": int(os.environ["VWPT_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": uuid,
                "email": "vwpt"
            }],
            "decryption": decryption
        },
        "streamSettings": {
            "network": "ws",
            "security": "none",
            "wsSettings": {
                "path": os.environ.get("VWPT_PATH", "/vwpt")
            }
        }
    })

config = {
    "log": {"loglevel": "warning"},
    "inbounds": inbounds,
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
    ]
}

with open("/usr/local/etc/xray/config.json", "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
PY
}

ENABLE_VLPT=0
ENABLE_XHPT=0
ENABLE_VWPT=0
ENABLE_ARGO=0

echo ""
echo "请选择需要安装的协议（可多选）"
echo "================================================="
echo "1) vlpt  VLESS + TCP + REALITY + Vision"
echo "2) xhpt  VLESS + XHTTP + REALITY + ENC"
echo "3) vwpt  VLESS + WS + TLS + CDN + ENC"
echo "================================================="
echo "输入示例："
echo "1       仅安装 vlpt"
echo "2       仅安装 xhpt"
echo "3       仅安装 vwpt"
echo "1 2 3   全部安装"
echo ""
read -p "请输入协议编号: " INSTALL_OPTIONS

for opt in $INSTALL_OPTIONS; do
  case "$opt" in
    1) ENABLE_VLPT=1 ;;
    2) ENABLE_XHPT=1 ;;
    3) ENABLE_VWPT=1 ;;
  esac
done

if [ "$ENABLE_VLPT" = "0" ] && [ "$ENABLE_XHPT" = "0" ] && [ "$ENABLE_VWPT" = "0" ]; then
  echo "未选择任何协议，已退出。"
  exit 0
fi

read -p "请输入 UUID，留空自动生成: " UUID
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

read -p "请输入 REALITY 连接地址，留空自动获取 VPS 公网 IPv4: " SERVER_IP
SERVER_IP=${SERVER_IP:-$(get_public_ip)}

REALITY_SNI=""
if [ "$ENABLE_VLPT" = "1" ] || [ "$ENABLE_XHPT" = "1" ]; then
  read -p "请输入 REALITY 伪装域名/SNI [默认 www.apple.com]: " REALITY_SNI
  REALITY_SNI=${REALITY_SNI:-www.apple.com}
fi

VLPT_PORT=""
XHPT_PORT=""
VWPT_PORT=""
XHPT_PATH=""
VWPT_PATH=""
VWPT_DOMAIN=""
CDN_MODE=0
CDN_ADDRESS=""

if [ "$ENABLE_VLPT" = "1" ]; then
  read -p "请输入 vlpt 端口 [默认随机]: " VLPT_PORT
  VLPT_PORT=${VLPT_PORT:-$(random_port)}
fi

if [ "$ENABLE_XHPT" = "1" ]; then
  read -p "请输入 xhpt 端口 [默认随机]: " XHPT_PORT
  read -p "请输入 xhpt Path [默认 /${UUID}-xh]: " XHPT_PATH
  XHPT_PORT=${XHPT_PORT:-$(random_port)}
  XHPT_PATH=${XHPT_PATH:-/${UUID}-xh}
fi

if [ "$ENABLE_VWPT" = "1" ]; then
  read -p "请输入 vwpt WS 回源端口 [默认随机]: " VWPT_PORT
  read -p "请输入 vwpt WS Path [默认 /${UUID}-vw]: " VWPT_PATH
  read -p "请输入 vwpt CDN 域名，例如 ws.example.com: " VWPT_DOMAIN
  VWPT_PORT=${VWPT_PORT:-$(random_port)}
  VWPT_PATH=${VWPT_PATH:-/${UUID}-vw}

  echo ""
  echo "CDN 优选设置："
  echo "0) 不启用，address 使用真实 CDN 域名"
  echo "1) 启用，默认 www.visa.cn"
  read -p "请选择 [默认 0]: " CDN_MODE
  CDN_MODE=${CDN_MODE:-0}
  if [ "$CDN_MODE" = "1" ]; then
    read -p "请输入 CDN 优选域名/IP [默认 www.visa.cn]: " CDN_ADDRESS
    CDN_ADDRESS=${CDN_ADDRESS:-www.visa.cn}
  fi

  echo ""
  echo "Argo / Cloudflare Tunnel 设置："
  echo "0) 不启用"
  echo "1) 临时隧道 trycloudflare.com"
  echo "2) 固定隧道 token"
  read -p "请选择 [默认 0]: " ENABLE_ARGO
  ENABLE_ARGO=${ENABLE_ARGO:-0}

  if [ "$ENABLE_ARGO" = "2" ]; then
    read -p "请输入 Argo 固定隧道域名，例如 tunnel.example.com: " ARGO_DOMAIN
    read -p "请输入 Argo 固定隧道 Token: " ARGO_TOKEN
  fi
fi

echo ""
echo "安装依赖..."
apt update -y
apt install -y curl unzip socat openssl nginx python3 coreutils lsb-release ca-certificates gnupg

echo ""
echo "安装 / 更新 Xray-core..."
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

mkdir -p /usr/local/etc/xray/

echo ""
echo "生成 REALITY 密钥..."
KEYS=$(/usr/local/bin/xray x25519)
XRAY_PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | head -n1 | cut -d ':' -f2 | tr -d '[:space:]')
XRAY_PUBLIC_KEY=$(echo "$KEYS" | grep -i "Public" | head -n1 | cut -d ':' -f2 | tr -d '[:space:]')
XRAY_SHORT_ID=$(openssl rand -hex 8)

if [ -z "$XRAY_PRIVATE_KEY" ] || [ -z "$XRAY_PUBLIC_KEY" ]; then
  echo "REALITY 密钥生成失败，xray x25519 输出如下："
  echo "$KEYS"
  exit 1
fi

# ENC 策略：
# 参考 ArgosBX 结构，xhpt/vwpt 默认尝试 ENC。
# 但不同 Xray 版本对 decryption 支持不一致，因此先写 ENC 测试，失败自动回退 none。
VLESS_DECRYPTION="none"
VLESS_ENCRYPTION="none"
ENC_STATUS="未启用或已回退 none"

if [ "$ENABLE_XHPT" = "1" ] || [ "$ENABLE_VWPT" = "1" ]; then
  echo ""
  echo "尝试启用 VLESS ENC..."
  # 优先使用简单兼容值；如果当前 Xray 不支持，会自动回退
  VLESS_DECRYPTION="mlkem768x25519plus.native.600s"
  VLESS_ENCRYPTION="mlkem768x25519plus.native.0rtt"

  write_config
  if test_xray_config; then
    ENC_STATUS="已启用：$VLESS_ENCRYPTION"
    echo "ENC 测试通过。"
  else
    echo "ENC 测试失败，自动回退 encryption=none。"
    echo "失败日志："
    cat /tmp/xray-config-test.log || true
    VLESS_DECRYPTION="none"
    VLESS_ENCRYPTION="none"
    ENC_STATUS="当前 Xray 不支持，已自动回退 none"
    write_config
    test_xray_config || { cat /tmp/xray-config-test.log; exit 1; }
  fi
else
  write_config
  test_xray_config || { cat /tmp/xray-config-test.log; exit 1; }
fi

if [ "$ENABLE_VWPT" = "1" ]; then
  echo ""
  echo "配置 Nginx TLS + WS 反代..."
  mkdir -p /etc/nginx/conf.d/
  mkdir -p /etc/ssl/xray/

  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout /etc/ssl/xray/vwpt.key \
    -out /etc/ssl/xray/vwpt.crt \
    -subj "/CN=$VWPT_DOMAIN"

  cat > /etc/nginx/conf.d/xray-vwpt.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $VWPT_DOMAIN;

    ssl_certificate /etc/ssl/xray/vwpt.crt;
    ssl_certificate_key /etc/ssl/xray/vwpt.key;

    location $VWPT_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$VWPT_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

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

ARGO_HOST=""
if [ "$ENABLE_VWPT" = "1" ] && [ "$ENABLE_ARGO" = "1" ]; then
  install_cloudflared
  echo ""
  echo "启动 Argo 临时隧道..."
  mkdir -p /var/log/cloudflared
  pkill -f "cloudflared tunnel --url http://127.0.0.1:$VWPT_PORT" || true
  nohup cloudflared tunnel --url http://127.0.0.1:$VWPT_PORT --edge-ip-version auto --no-autoupdate --protocol http2 > /var/log/cloudflared/quick-tunnel.log 2>&1 &
  sleep 8
  ARGO_HOST=$(grep -oE "https://[-a-zA-Z0-9.]+\.trycloudflare\.com" /var/log/cloudflared/quick-tunnel.log | head -n1 | sed 's#https://##')
  [ -z "$ARGO_HOST" ] && echo "未自动获取 trycloudflare 域名，请查看 /var/log/cloudflared/quick-tunnel.log"
fi

if [ "$ENABLE_VWPT" = "1" ] && [ "$ENABLE_ARGO" = "2" ]; then
  install_cloudflared
  echo ""
  echo "安装 Argo 固定隧道服务..."
  if [ -z "$ARGO_TOKEN" ]; then
    echo "未填写 Argo Token，跳过固定隧道。"
  else
    cloudflared service uninstall >/dev/null 2>&1 || true
    cloudflared service install "$ARGO_TOKEN"
    systemctl enable cloudflared
    systemctl restart cloudflared
    ARGO_HOST="$ARGO_DOMAIN"
  fi
fi

ENC_URL=$(urlencode "$VLESS_ENCRYPTION")
OUTPUT_FILE=~/xray-argosbx-style-client.txt

cat > "$OUTPUT_FILE" <<EOF
=================================================
Xray-core ArgosBX-style 客户端信息
=================================================
UUID: $UUID
VPS 地址: $SERVER_IP
ENC 状态: $ENC_STATUS
Client encryption: $VLESS_ENCRYPTION
Server decryption: $VLESS_DECRYPTION

EOF

if [ "$ENABLE_VLPT" = "1" ]; then
  VLPT_LINK="vless://${UUID}@${SERVER_IP}:${VLPT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp&headerType=none#vlpt-vless-tcp-reality-vision"
  cat >> "$OUTPUT_FILE" <<EOF
=================================================
vlpt: VLESS + TCP + REALITY + Vision
=================================================
$VLPT_LINK

端口: $VLPT_PORT
SNI: $REALITY_SNI
PublicKey: $XRAY_PUBLIC_KEY
ShortID: $XRAY_SHORT_ID

EOF
fi

if [ "$ENABLE_XHPT" = "1" ]; then
  XHPT_LINK="vless://${UUID}@${SERVER_IP}:${XHPT_PORT}?encryption=${ENC_URL}&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=xhttp&path=$(urlencode "$XHPT_PATH")&mode=auto#xhpt-vless-xhttp-reality-enc"
  cat >> "$OUTPUT_FILE" <<EOF
=================================================
xhpt: VLESS + XHTTP + REALITY + ENC
=================================================
$XHPT_LINK

端口: $XHPT_PORT
Path: $XHPT_PATH
SNI: $REALITY_SNI
PublicKey: $XRAY_PUBLIC_KEY
ShortID: $XRAY_SHORT_ID

EOF
fi

if [ "$ENABLE_VWPT" = "1" ]; then
  VWPT_CLIENT_ADDRESS="$VWPT_DOMAIN"
  if [ "$CDN_MODE" = "1" ]; then
    VWPT_CLIENT_ADDRESS="$CDN_ADDRESS"
    CDN_STATUS="启用：$CDN_ADDRESS"
  else
    CDN_STATUS="未启用"
  fi

  VWPT_LINK="vless://${UUID}@${VWPT_CLIENT_ADDRESS}:443?encryption=${ENC_URL}&security=tls&type=ws&host=${VWPT_DOMAIN}&path=$(urlencode "$VWPT_PATH")&sni=${VWPT_DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1#vwpt-vless-ws-tls-cdn-enc"
  cat >> "$OUTPUT_FILE" <<EOF
=================================================
vwpt: VLESS + WS + TLS + CDN + ENC
=================================================
$VWPT_LINK

真实 CDN 域名: $VWPT_DOMAIN
客户端 address: $VWPT_CLIENT_ADDRESS
WS Path: $VWPT_PATH
WS 回源端口: $VWPT_PORT
CDN 优选: $CDN_STATUS

EOF

  if [ -n "$ARGO_HOST" ]; then
    ARGO_TLS_LINK="vless://${UUID}@www.visa.cn:443?encryption=${ENC_URL}&security=tls&type=ws&host=${ARGO_HOST}&path=$(urlencode "$VWPT_PATH")&sni=${ARGO_HOST}&fp=chrome&alpn=h2%2Chttp%2F1.1#vwpt-vless-ws-tls-argo-enc"
    ARGO_HTTP_LINK="vless://${UUID}@www.visa.cn:80?encryption=${ENC_URL}&security=none&type=ws&host=${ARGO_HOST}&path=$(urlencode "$VWPT_PATH")#vwpt-vless-ws-argo-enc"
    cat >> "$OUTPUT_FILE" <<EOF
=================================================
argo: Cloudflare Tunnel，绑定 vwpt
=================================================
Argo Host: $ARGO_HOST
Argo 回源: http://127.0.0.1:$VWPT_PORT

TLS 443:
$ARGO_TLS_LINK

HTTP 80:
$ARGO_HTTP_LINK

EOF
  fi
fi

cat >> "$OUTPUT_FILE" <<EOF
=================================================
排错命令
=================================================
systemctl status xray --no-pager
journalctl -u xray -n 100 --no-pager
cat /usr/local/etc/xray/config.json
nginx -t
systemctl status nginx --no-pager
ss -lntp

=================================================
说明
=================================================
1. vlpt 使用 TCP + REALITY + Vision，flow=xtls-rprx-vision。
2. xhpt 使用 XHTTP + REALITY，ENC 会先测试，不支持自动回退 none。
3. vwpt 使用 WS + TLS + CDN，ENC 会先测试，不支持自动回退 none。
4. Argo 只绑定 vwpt，固定隧道需要在 Cloudflare Zero Trust 中设置 Service URL 为 http://127.0.0.1:$VWPT_PORT。
5. CDN 优选只改变客户端 address，host/sni 仍为真实域名。
EOF

echo ""
echo "================================================="
echo " 安装完成，客户端信息如下"
echo "================================================="
cat "$OUTPUT_FILE"
echo ""
echo "客户端信息已保存到：$OUTPUT_FILE"
