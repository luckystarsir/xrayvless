#!/usr/bin/env bash
set -e

echo "================================================="
echo " Xray-core 稳定增强版一键脚本 v2"
echo " 1. VLESS + XHTTP + REALITY"
echo " 2. VLESS + WS + TLS + CDN"
echo " 可选：VLESS Encryption / ENC"
echo "================================================="

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行：sudo bash $0"
  exit 1
fi

random_port() { shuf -i 20000-50000 -n 1; }
urlencode() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

INSTALL_REALITY=0
INSTALL_WS=0
ENABLE_ENC=0

echo ""
echo "请选择需要安装的协议（可多选）"
echo "================================================="
echo "1) VLESS + XHTTP + REALITY"
echo "2) VLESS + WS + TLS + CDN"
echo "================================================="
echo "输入示例：1 / 2 / 1 2"
read -p "请输入协议编号: " INSTALL_OPTIONS

for opt in $INSTALL_OPTIONS; do
  case "$opt" in
    1) INSTALL_REALITY=1 ;;
    2) INSTALL_WS=1 ;;
  esac
done

if [ "$INSTALL_REALITY" = "0" ] && [ "$INSTALL_WS" = "0" ]; then
  echo "未选择任何协议，已退出。"
  exit 0
fi

echo ""
echo "VLESS Encryption / ENC 设置："
echo "0) 不启用，使用 encryption=none，兼容性最好"
echo "1) 启用，由 xray vlessenc 自动生成"
read -p "请选择 [默认 0]: " ENABLE_ENC
ENABLE_ENC=${ENABLE_ENC:-0}

read -p "请输入 UUID，留空自动生成: " UUID
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

REALITY_ADDRESS=""
REALITY_PORT=""
REALITY_SNI=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

WS_DOMAIN=""
WS_PORT=""
WS_PATH=""
CDN_PREFERRED_MODE=0
CDN_ADDRESS=""

VLESS_DECRYPTION="none"
VLESS_ENCRYPTION="none"

if [ "$INSTALL_REALITY" = "1" ]; then
  echo ""
  echo "配置 1) VLESS + XHTTP + REALITY"
  read -p "请输入 REALITY 连接地址，VPS IP 或域名，留空自动获取公网 IPv4: " REALITY_ADDRESS
  read -p "请输入 REALITY 端口 [默认随机]: " REALITY_PORT
  read -p "请输入 REALITY 伪装域名/SNI [默认 www.cloudflare.com]: " REALITY_SNI
  REALITY_PORT=${REALITY_PORT:-$(random_port)}
  REALITY_SNI=${REALITY_SNI:-www.cloudflare.com}
fi

if [ "$INSTALL_WS" = "1" ]; then
  echo ""
  echo "配置 2) VLESS + WS + TLS + CDN"
  read -p "请输入 WS CDN 域名，例如 ws.example.com: " WS_DOMAIN
  read -p "请输入 WS 回源端口 [默认随机]: " WS_PORT
  read -p "请输入 WS Path [默认 /ws]: " WS_PATH
  WS_PORT=${WS_PORT:-$(random_port)}
  WS_PATH=${WS_PATH:-/ws}

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
apt install -y curl unzip socat openssl nginx python3 coreutils

if [ "$INSTALL_REALITY" = "1" ] && [ -z "$REALITY_ADDRESS" ]; then
  REALITY_ADDRESS=$(curl -4s --max-time 5 https://api.ipify.org || true)
  if [ -z "$REALITY_ADDRESS" ]; then
    REALITY_ADDRESS=$(hostname -I | awk '{print $1}')
  fi
fi

echo ""
echo "安装 / 更新 Xray-core..."
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

if [ "$ENABLE_ENC" = "1" ]; then
  echo ""
  echo "启用 VLESS Encryption / ENC 兼容模式..."
  echo "服务端 decryption: mlkem768x25519plus.native.600s"
  echo "客户端 encryption: mlkem768x25519plus.native.0rtt"

  # 兼容模式：不使用 xray vlessenc 生成的带认证参数长格式，避免部分版本报 unsupported decryption
  VLESS_DECRYPTION="mlkem768x25519plus.native.600s"
  VLESS_ENCRYPTION="mlkem768x25519plus.native.0rtt"
fi

if [ "$INSTALL_REALITY" = "1" ]; then
  echo ""
  echo "生成 REALITY 密钥..."
  KEYS=$(/usr/local/bin/xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | head -n1 | cut -d ':' -f2 | tr -d '[:space:]')
  PUBLIC_KEY=$(echo "$KEYS" | grep -i "Public" | head -n1 | cut -d ':' -f2 | tr -d '[:space:]')
  SHORT_ID=$(openssl rand -hex 8)

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "REALITY 密钥生成失败，xray x25519 输出如下："
    echo "$KEYS"
    exit 1
  fi
fi

mkdir -p /usr/local/etc/xray/

export INSTALL_REALITY INSTALL_WS UUID VLESS_DECRYPTION
export REALITY_PORT REALITY_SNI PRIVATE_KEY SHORT_ID
export WS_PORT WS_PATH

python3 <<'PY'
import json
import os

install_reality = os.environ.get("INSTALL_REALITY") == "1"
install_ws = os.environ.get("INSTALL_WS") == "1"
uuid = os.environ["UUID"]
decryption = os.environ.get("VLESS_DECRYPTION", "none")

inbounds = []

if install_reality:
    inbounds.append({
        "tag": "vless-xhttp-reality",
        "listen": "0.0.0.0",
        "port": int(os.environ["REALITY_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [
                {
                    "id": uuid,
                    "email": "xhttp-reality"
                }
            ],
            "decryption": decryption
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "dest": f"{os.environ['REALITY_SNI']}:443",
                "xver": 0,
                "serverNames": [os.environ["REALITY_SNI"]],
                "privateKey": os.environ["PRIVATE_KEY"],
                "shortIds": [os.environ["SHORT_ID"]]
            }
        }
    })

if install_ws:
    inbounds.append({
        "tag": "vless-ws-cdn",
        "listen": "127.0.0.1",
        "port": int(os.environ["WS_PORT"]),
        "protocol": "vless",
        "settings": {
            "clients": [
                {
                    "id": uuid,
                    "email": "ws-cdn"
                }
            ],
            "decryption": decryption
        },
        "streamSettings": {
            "network": "ws",
            "security": "none",
            "wsSettings": {
                "path": os.environ["WS_PATH"]
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

echo ""
echo "检查 Xray 配置..."
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json

if [ "$INSTALL_WS" = "1" ]; then
  echo ""
  echo "配置 Nginx TLS + WS 反代..."
  mkdir -p /etc/nginx/conf.d/
  mkdir -p /etc/ssl/xray/

  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout /etc/ssl/xray/ws.key \
    -out /etc/ssl/xray/ws.crt \
    -subj "/CN=$WS_DOMAIN"

  cat > /etc/nginx/conf.d/xray-ws-cdn.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $WS_DOMAIN;

    ssl_certificate /etc/ssl/xray/ws.crt;
    ssl_certificate_key /etc/ssl/xray/ws.key;

    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$WS_PORT;
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

ENC_URL=$(urlencode "$VLESS_ENCRYPTION")

OUTPUT_FILE=~/vless-stable-xhttp-enc-client.txt
cat > "$OUTPUT_FILE" <<EOF
=================================================
Xray-core 稳定增强版客户端信息
=================================================
UUID: $UUID
ENC / Client Encryption: $VLESS_ENCRYPTION
Server Decryption: $VLESS_DECRYPTION

EOF

if [ "$INSTALL_REALITY" = "1" ]; then
  REALITY_LINK="vless://${UUID}@${REALITY_ADDRESS}:${REALITY_PORT}?encryption=${ENC_URL}&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp#VLESS-XHTTP-REALITY"
  cat >> "$OUTPUT_FILE" <<EOF
=================================================
VLESS + XHTTP + REALITY
=================================================
$REALITY_LINK

REALITY 连接地址: $REALITY_ADDRESS
REALITY 端口: $REALITY_PORT
REALITY SNI: $REALITY_SNI
REALITY PublicKey: $PUBLIC_KEY
REALITY ShortID: $SHORT_ID
Transport: xhttp

EOF
fi

if [ "$INSTALL_WS" = "1" ]; then
  WS_CLIENT_ADDRESS="$WS_DOMAIN"
  if [ "$CDN_PREFERRED_MODE" = "1" ]; then
    WS_CLIENT_ADDRESS="$CDN_ADDRESS"
    CDN_STATUS="启用：$CDN_ADDRESS"
  else
    CDN_STATUS="未启用"
  fi

  WS_PATH_URL=$(urlencode "$WS_PATH")
  WS_LINK="vless://${UUID}@${WS_CLIENT_ADDRESS}:443?encryption=${ENC_URL}&security=tls&type=ws&host=${WS_DOMAIN}&path=${WS_PATH_URL}&sni=${WS_DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1#VLESS-WS-TLS-CDN"

  cat >> "$OUTPUT_FILE" <<EOF
=================================================
VLESS + WS + TLS + CDN
=================================================
$WS_LINK

WS CDN 真实域名: $WS_DOMAIN
WS 客户端连接地址: $WS_CLIENT_ADDRESS
WS Path: $WS_PATH
WS 回源端口: $WS_PORT
CDN 优选状态: $CDN_STATUS

EOF
fi

cat >> "$OUTPUT_FILE" <<EOF
=================================================
排错命令
=================================================
systemctl status xray --no-pager
journalctl -u xray -n 80 --no-pager
systemctl status nginx --no-pager
nginx -t
ss -lntp

=================================================
使用说明
=================================================
1. 客户端请选择 Xray-core 内核。
2. REALITY 是 type=xhttp。
3. ENC 启用时，客户端必须支持 Xray VLESS Encryption。
4. 如果客户端不支持 ENC，请重新运行脚本并选择不启用 ENC。
5. WS + TLS + CDN 需要 Cloudflare DNS 开橙云。
6. Cloudflare SSL/TLS 建议选择 Full；不要选 Flexible。
EOF

echo ""
echo "================================================="
echo " 安装完成，客户端信息如下"
echo "================================================="
cat "$OUTPUT_FILE"
echo ""
echo "客户端信息已保存到：$OUTPUT_FILE"
