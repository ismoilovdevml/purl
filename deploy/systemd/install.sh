#!/bin/bash
# Purl + Vector installation script for systemd-based systems
# Tested on: Ubuntu 22.04, Debian 12, CentOS 9

set -e

PURL_DIR="/opt/purl"
PURL_USER="purl"
VECTOR_USER="vector"
PURL_URL="${PURL_URL:-http://localhost:3000}"

echo "=== Purl Installation Script ==="

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Detect package manager
if command -v apt-get &> /dev/null; then
    PKG_MGR="apt"
elif command -v dnf &> /dev/null; then
    PKG_MGR="dnf"
elif command -v yum &> /dev/null; then
    PKG_MGR="yum"
else
    echo "Unsupported package manager"
    exit 1
fi

echo "Step 1: Installing dependencies..."
case $PKG_MGR in
    apt)
        apt-get update
        apt-get install -y perl cpanminus nodejs npm curl wget
        ;;
    dnf|yum)
        $PKG_MGR install -y perl perl-App-cpanminus nodejs npm curl wget
        ;;
esac

echo "Step 2: Installing ClickHouse..."
if ! command -v clickhouse-server &> /dev/null; then
    case $PKG_MGR in
        apt)
            curl https://clickhouse.com/ | sh
            ./clickhouse install
            ;;
        dnf|yum)
            $PKG_MGR install -y yum-utils
            $PKG_MGR-config-manager --add-repo https://packages.clickhouse.com/rpm/clickhouse.repo
            $PKG_MGR install -y clickhouse-server clickhouse-client
            ;;
    esac
    systemctl enable clickhouse-server
    systemctl start clickhouse-server
fi

echo "Step 3: Installing Vector..."
if ! command -v vector &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSfL https://sh.vector.dev | bash -s -- -y
fi

echo "Step 4: Creating users..."
id -u $PURL_USER &>/dev/null || useradd -r -s /bin/false $PURL_USER
id -u $VECTOR_USER &>/dev/null || useradd -r -s /bin/false $VECTOR_USER

echo "Step 5: Setting up Purl..."
mkdir -p $PURL_DIR
if [ ! -d "$PURL_DIR/.git" ]; then
    git clone https://github.com/your-username/purl.git $PURL_DIR
fi

cd $PURL_DIR
cpanm --installdeps .
cd web && npm install && npm run build && cd ..
chown -R $PURL_USER:$PURL_USER $PURL_DIR

echo "Step 6: Configuring Vector..."
mkdir -p /etc/vector /var/lib/vector
cp deploy/systemd/vector.yaml /etc/vector/vector.yaml
sed -i "s|http://localhost:3000|$PURL_URL|g" /etc/vector/vector.yaml
chown -R $VECTOR_USER:$VECTOR_USER /var/lib/vector

echo "Step 7: Installing systemd services..."
cp deploy/systemd/purl.service /etc/systemd/system/
cp deploy/systemd/vector.service /etc/systemd/system/
systemctl daemon-reload

echo "Step 8: Starting services..."
systemctl enable purl vector
systemctl start purl
sleep 5
systemctl start vector

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Purl Dashboard: http://localhost:3000"
echo ""
echo "Services:"
echo "  systemctl status purl"
echo "  systemctl status vector"
echo "  systemctl status clickhouse-server"
echo ""
echo "Logs:"
echo "  journalctl -u purl -f"
echo "  journalctl -u vector -f"
