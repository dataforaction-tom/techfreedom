#!/usr/bin/env bash
# ============================================================
# TechFreedom — Server Setup Script
# Target: Hetzner CAX11 (ARM64), Ubuntu 24.04
# Run as root: ssh root@YOUR_IP 'bash -s' < setup.sh
# ============================================================
set -euo pipefail

POCKETBASE_VERSION="0.25.9"
POCKETBASE_DIR="/opt/pocketbase"
POCKETBASE_USER="pocketbase"
DOMAIN="api.techfreedom.eu"

echo "=== TechFreedom Server Setup ==="
echo "PocketBase ${POCKETBASE_VERSION} + Caddy on ARM64"
echo ""

# ---- 1. System updates ----
echo "[1/6] Updating system..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq unzip wget curl python3 python3-pip

# ---- 2. Create pocketbase user ----
echo "[2/6] Creating pocketbase user..."
if ! id "${POCKETBASE_USER}" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${POCKETBASE_USER}"
fi

# ---- 3. Install PocketBase ----
echo "[3/6] Installing PocketBase ${POCKETBASE_VERSION}..."
mkdir -p "${POCKETBASE_DIR}"

ARCH=$(uname -m)
if [ "${ARCH}" = "aarch64" ]; then
    PB_ARCH="arm64"
elif [ "${ARCH}" = "x86_64" ]; then
    PB_ARCH="amd64"
else
    echo "Unsupported architecture: ${ARCH}"
    exit 1
fi

wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${POCKETBASE_VERSION}/pocketbase_${POCKETBASE_VERSION}_linux_${PB_ARCH}.zip" \
    -O /tmp/pocketbase.zip
unzip -o /tmp/pocketbase.zip -d "${POCKETBASE_DIR}"
rm /tmp/pocketbase.zip
chmod +x "${POCKETBASE_DIR}/pocketbase"
chown -R "${POCKETBASE_USER}:${POCKETBASE_USER}" "${POCKETBASE_DIR}"

# ---- 4. Create systemd service ----
echo "[4/6] Setting up PocketBase systemd service..."
cat > /etc/systemd/system/pocketbase.service <<UNIT
[Unit]
Description=PocketBase
After=network.target

[Service]
Type=simple
User=${POCKETBASE_USER}
Group=${POCKETBASE_USER}
ExecStart=${POCKETBASE_DIR}/pocketbase serve --http=127.0.0.1:8090
WorkingDirectory=${POCKETBASE_DIR}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${POCKETBASE_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable pocketbase
systemctl start pocketbase

echo "    PocketBase running on 127.0.0.1:8090"

# ---- 5. Install Caddy ----
echo "[5/6] Installing Caddy..."
apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
apt-get update -qq
apt-get install -y -qq caddy

# Write Caddyfile
cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
    reverse_proxy 127.0.0.1:8090

    header {
        # CORS for techfreedom.eu
        Access-Control-Allow-Origin https://techfreedom.eu
        Access-Control-Allow-Methods "GET, POST, OPTIONS"
        Access-Control-Allow-Headers "Content-Type, Authorization"
        Access-Control-Max-Age 86400

        # Security headers
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    @options method OPTIONS
    respond @options 204

    log {
        output file /var/log/caddy/techfreedom.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}
CADDY

mkdir -p /var/log/caddy
systemctl restart caddy

echo "    Caddy configured for ${DOMAIN} (auto-TLS via Let's Encrypt)"

# ---- 6. Backup cron ----
echo "[6/6] Setting up daily backup..."
mkdir -p /opt/backups/pocketbase

cat > /opt/backups/backup-pocketbase.sh <<'BACKUP'
#!/usr/bin/env bash
# Daily PocketBase backup — SQLite snapshot
set -euo pipefail

BACKUP_DIR="/opt/backups/pocketbase"
PB_DIR="/opt/pocketbase"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
KEEP_DAYS=14

# Use sqlite3 backup command for a consistent snapshot
if command -v sqlite3 &>/dev/null; then
    sqlite3 "${PB_DIR}/pb_data/data.db" ".backup '${BACKUP_DIR}/data-${TIMESTAMP}.db'"
else
    # Fallback: copy the file (less safe but works without sqlite3)
    cp "${PB_DIR}/pb_data/data.db" "${BACKUP_DIR}/data-${TIMESTAMP}.db"
fi

# Compress
gzip "${BACKUP_DIR}/data-${TIMESTAMP}.db"

# Remove backups older than KEEP_DAYS
find "${BACKUP_DIR}" -name "data-*.db.gz" -mtime +${KEEP_DAYS} -delete

echo "[$(date)] Backup complete: data-${TIMESTAMP}.db.gz"
BACKUP

chmod +x /opt/backups/backup-pocketbase.sh

# Install sqlite3 for safe backups
apt-get install -y -qq sqlite3

# Add cron job (daily at 03:00)
(crontab -l 2>/dev/null | grep -v backup-pocketbase; echo "0 3 * * * /opt/backups/backup-pocketbase.sh >> /var/log/pocketbase-backup.log 2>&1") | crontab -

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Point DNS: ${DOMAIN} -> $(curl -s4 ifconfig.me || echo 'YOUR_SERVER_IP')"
echo "  2. Wait for DNS propagation (check: dig ${DOMAIN})"
echo "  3. Caddy will auto-provision TLS once DNS resolves"
echo "  4. Create admin account: https://${DOMAIN}/_/"
echo "  5. Run import-data.py to create collections and import data"
echo ""
echo "Service status:"
systemctl is-active pocketbase && echo "  PocketBase: running" || echo "  PocketBase: NOT running"
systemctl is-active caddy && echo "  Caddy: running" || echo "  Caddy: NOT running"
