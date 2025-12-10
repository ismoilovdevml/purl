#!/bin/bash
# Purl Systemd Installation Script
# Usage: sudo ./install.sh

set -e

echo "=== Purl Systemd Installation ==="

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./install.sh)"
    exit 1
fi

# Variables
PURL_DIR="/opt/purl"
PURL_USER="purl"
CONFIG_DIR="/etc/purl"

echo "[1/6] Creating user and directories..."
useradd -r -s /bin/false $PURL_USER 2>/dev/null || true
mkdir -p $PURL_DIR $CONFIG_DIR $PURL_DIR/data

echo "[2/6] Copying application files..."
cp -r lib bin web $PURL_DIR/
chown -R $PURL_USER:$PURL_USER $PURL_DIR

echo "[3/6] Installing configuration..."
if [ ! -f $CONFIG_DIR/purl.env ]; then
    cp .env.example $CONFIG_DIR/purl.env
    echo "  Created $CONFIG_DIR/purl.env - please edit with your settings"
fi

echo "[4/6] Installing systemd services..."
cp deploy/systemd/purl.service /etc/systemd/system/
cp deploy/systemd/vector.service /etc/systemd/system/

echo "[5/6] Installing Vector config..."
mkdir -p /etc/vector
cp deploy/vector/vector.toml /etc/vector/

echo "[6/6] Enabling services..."
systemctl daemon-reload
systemctl enable purl

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit configuration: vim $CONFIG_DIR/purl.env"
echo "  2. Start ClickHouse:   systemctl start clickhouse-server"
echo "  3. Start Purl:         systemctl start purl"
echo "  4. Start Vector:       systemctl start vector"
echo "  5. Check status:       systemctl status purl"
echo "  6. View logs:          journalctl -u purl -f"
echo ""
