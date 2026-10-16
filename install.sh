#!/bin/bash
# Yange Core Installer: Panel & Node
#
# Install Panel:
#   curl -fsSL https://raw.githubusercontent.com/Greufsik/yange-core/main/install.sh | sudo bash
#
# Install Node:
#   curl -fsSL https://raw.githubusercontent.com/Greufsik/yange-core/main/install.sh | sudo bash -s -- --join <KEY>

set -e

REPO="Greufsik/yange-core"
RELEASE_URL="https://github.com/$REPO/releases/latest/download"

# Check root
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] Пожалуйста, запустите установщик от имени root (sudo bash)." >&2
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    ARCH_SUFFIX="amd64"
    ;;
  aarch64|arm64)
    ARCH_SUFFIX="arm64"
    ;;
  *)
    echo "[ERROR] Архитектура $ARCH не поддерживается." >&2
    exit 1
    ;;
esac

# Parse arguments
JOIN_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --join)
      JOIN_KEY="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Ensure basic utilities
command -v curl >/dev/null 2>&1 || {
  echo "Установка curl..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl
  fi
}

mkdir -p /var/lib/yange/node /run/yange /etc/yange
chmod 700 /var/lib/yange/node
chmod 755 /run/yange

# ----------------------------------------------------
# 1. NODE INSTALLATION MODE (--join KEY)
# ----------------------------------------------------
if [ -n "$JOIN_KEY" ]; then
  echo "=========================================================="
  echo "  Установка Yange Node (Data Plane)..."
  echo "=========================================================="

  echo "Скачивание yange-node..."
  curl -fsSL "$RELEASE_URL/yange-node" -o /usr/local/bin/yange-node
  chmod +x /usr/local/bin/yange-node

  cat <<EOF > /etc/yange/node.env
YANGE_DATA_DIR=/var/lib/yange/node
YANGE_NODE_SOCKET=/run/yange/node.sock
YANGE_NODE_JOIN=$JOIN_KEY
EOF
  chmod 600 /etc/yange/node.env

  cat <<'EOF' > /etc/systemd/system/yange-node.service
[Unit]
Description=Yange Node Data Plane
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/yange/node.env
ExecStart=/usr/local/bin/yange-node
Restart=always
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now yange-node

  # Open firewall ports if UFW is installed
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "Настройка портов UFW..."
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw allow 443/udp >/dev/null 2>&1 || true
    ufw allow 8443/tcp >/dev/null 2>&1 || true
    ufw allow 8443/udp >/dev/null 2>&1 || true
    API_PORT=$(YANGE_NODE_JOIN="$JOIN_KEY" /usr/local/bin/yange-node key-port 2>/dev/null || true)
    if [ -n "$API_PORT" ]; then
      ufw allow "$API_PORT/tcp" >/dev/null 2>&1 || true
    fi
    ufw reload >/dev/null 2>&1 || true
  fi

  echo ""
  echo "=========================================================="
  echo "  ✅ Yange Node успешно установлена и запущена!"
  echo "  Нода подключилась к вашей панели управления."
  echo "  Через 15–30 секунд статус в панели станет «Работает»."
  echo "=========================================================="
  exit 0
fi

# ----------------------------------------------------
# 2. FULL PANEL INSTALLATION MODE
# ----------------------------------------------------
echo "=========================================================="
echo "  Установка Yange Core (Панель управления + База данных)..."
echo "=========================================================="

echo "Скачивание компонентов yange и yange-node..."
curl -fsSL "$RELEASE_URL/yange" -o /usr/local/bin/yange
curl -fsSL "$RELEASE_URL/yange-node" -o /usr/local/bin/yange-node
chmod +x /usr/local/bin/yange /usr/local/bin/yange-node

mkdir -p /var/lib/yange/panel
chmod 700 /var/lib/yange/panel

# Install PostgreSQL if needed
if ! command -v psql >/dev/null 2>&1; then
  echo "Установка PostgreSQL..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib
  fi
fi

systemctl enable --now postgresql

# Generate database password
DB_PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
if [ -z "$DB_PASS" ]; then
  DB_PASS="YangeSecurePass2026"
fi

echo "Настройка базы данных PostgreSQL..."
sudo -u postgres psql -c "CREATE USER yange WITH PASSWORD '$DB_PASS';" >/dev/null 2>&1 || sudo -u postgres psql -c "ALTER USER yange WITH PASSWORD '$DB_PASS';" >/dev/null 2>&1
sudo -u postgres psql -c "CREATE DATABASE yange OWNER yange;" >/dev/null 2>&1 || true
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE yange TO yange;" >/dev/null 2>&1

cat <<EOF > /etc/yange/yange.env
YANGE_DATABASE_URL=postgres://yange:$DB_PASS@127.0.0.1:5432/yange?sslmode=disable
YANGE_DATA_DIR=/var/lib/yange/panel
YANGE_PANEL_LISTEN=0.0.0.0:2053
YANGE_NODE_SOCKET=/run/yange/node.sock
YANGE_LOG_LEVEL=info
EOF
chmod 600 /etc/yange/yange.env

cat <<'EOF' > /etc/yange/node.env
YANGE_DATA_DIR=/var/lib/yange/node
YANGE_NODE_SOCKET=/run/yange/node.sock
EOF
chmod 600 /etc/yange/node.env

cat <<'EOF' > /etc/systemd/system/yange-node.service
[Unit]
Description=Yange Node Data Plane
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/yange/node.env
ExecStart=/usr/local/bin/yange-node
Restart=always
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' > /etc/systemd/system/yange.service
[Unit]
Description=Yange Core Management Panel
After=network.target postgresql.service yange-node.service
Wants=postgresql.service yange-node.service

[Service]
Type=simple
EnvironmentFile=/etc/yange/yange.env
ExecStart=/usr/local/bin/yange serve
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now yange-node

# Detect public IP
PUBLIC_IP=$(curl -4s --connect-timeout 5 https://api.ipify.org || curl -4s --connect-timeout 5 https://ifconfig.me || curl -4s --connect-timeout 5 https://icanhazip.com || echo "")
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

echo "Инициализация панели управления (bootstrap)..."
set -a
. /etc/yange/yange.env
set +a
/usr/local/bin/yange admin bootstrap --public-host "$PUBLIC_IP" --port 2053 --username admin --lang ru

systemctl enable --now yange

# Configure firewall
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "Настройка портов UFW..."
  ufw allow 2053/tcp >/dev/null 2>&1 || true
  ufw allow 443 >/dev/null 2>&1 || true
  ufw allow 8443 >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
fi

echo ""
echo "=========================================================="
echo "  ✅ Yange Core успешно установлена и запущена!"
echo ""
/usr/local/bin/yange admin url
echo "=========================================================="
