#!/bin/bash
# Vector Agent Installation for Purl
# Usage: curl -fsSL https://purl.example.com/vector-install.sh | bash -s -- --clickhouse http://ch:8123

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLICKHOUSE_URL=""
PURL_API_URL=""
PURL_API_KEY=""
ENVIRONMENT="production"
INSTALL_TYPE="docker"  # docker or binary

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --clickhouse URL    ClickHouse URL (recommended)"
    echo "  --purl-api URL      Purl API URL (alternative to ClickHouse)"
    echo "  --api-key KEY       API key for Purl API"
    echo "  --env ENV           Environment label (default: production)"
    echo "  --type TYPE         Install type: docker or binary (default: docker)"
    echo "  --help              Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --clickhouse) CLICKHOUSE_URL="$2"; shift 2 ;;
        --purl-api) PURL_API_URL="$2"; shift 2 ;;
        --api-key) PURL_API_KEY="$2"; shift 2 ;;
        --env) ENVIRONMENT="$2"; shift 2 ;;
        --type) INSTALL_TYPE="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$CLICKHOUSE_URL" ] && [ -z "$PURL_API_URL" ]; then
    echo -e "${RED}Error: --clickhouse or --purl-api required${NC}"
    exit 1
fi

echo -e "${GREEN}Installing Vector for Purl...${NC}"

# Create config directory
sudo mkdir -p /etc/vector

# Generate config based on destination
if [ -n "$CLICKHOUSE_URL" ]; then
    SINK_CONFIG=$(cat <<EOF
[sinks.clickhouse]
type = "clickhouse"
inputs = ["filtered"]
endpoint = "$CLICKHOUSE_URL"
database = "purl"
table = "logs"
skip_unknown_fields = true
compression = "gzip"
batch.max_events = 10000
batch.timeout_secs = 5
buffer.type = "disk"
buffer.max_size = 268435488
EOF
)
else
    SINK_CONFIG=$(cat <<EOF
[sinks.purl_api]
type = "http"
inputs = ["filtered"]
uri = "${PURL_API_URL}/api/logs"
method = "post"
compression = "gzip"
encoding.codec = "json"
batch.max_events = 1000
batch.timeout_secs = 5
request.headers.Content-Type = "application/json"
request.headers.X-API-Key = "$PURL_API_KEY"
EOF
)
fi

# Create Vector config
sudo tee /etc/vector/vector.toml > /dev/null <<EOF
data_dir = "/var/lib/vector"

[api]
enabled = true
address = "0.0.0.0:8686"

[sources.docker]
type = "docker_logs"
exclude_containers = ["vector"]

[sources.journald]
type = "journald"
current_boot_only = true

[transforms.parsed]
type = "remap"
inputs = ["docker", "journald"]
source = '''
.service = .container_name ?? ._SYSTEMD_UNIT ?? "unknown"
.host = get_env_var("HOSTNAME") ?? "unknown"
.timestamp = to_timestamp(.timestamp) ?? now()
.raw = .message
.meta.environment = "$ENVIRONMENT"
.meta.source = "vector"

msg_upper = upcase(string!(.message))
if contains(msg_upper, "ERROR") {
  .level = "ERROR"
} else if contains(msg_upper, "WARN") {
  .level = "WARN"
} else {
  .level = "INFO"
}

del(.container_id)
del(.container_name)
del(._SYSTEMD_UNIT)
'''

[transforms.filtered]
type = "filter"
inputs = ["parsed"]
condition = 'length(.message) > 0'

$SINK_CONFIG
EOF

echo -e "${GREEN}Config created at /etc/vector/vector.toml${NC}"

if [ "$INSTALL_TYPE" = "docker" ]; then
    # Docker installation
    echo -e "${YELLOW}Installing via Docker...${NC}"

    docker run -d \
        --name purl-vector \
        --restart unless-stopped \
        -v /etc/vector:/etc/vector:ro \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v /var/log:/var/log:ro \
        -v vector-data:/var/lib/vector \
        -e HOSTNAME=$(hostname) \
        timberio/vector:0.51.1-alpine

    echo -e "${GREEN}Vector running as Docker container${NC}"
    echo -e "${YELLOW}Check status: docker logs purl-vector${NC}"
else
    # Binary installation
    echo -e "${YELLOW}Installing Vector binary...${NC}"

    curl -fsSL https://sh.vector.dev | bash -s -- -y

    # Create systemd service
    sudo tee /etc/systemd/system/vector.service > /dev/null <<'SVC'
[Unit]
Description=Vector Log Collector
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/vector --config /etc/vector/vector.toml
Restart=always
RestartSec=5
Environment="HOSTNAME=%H"

[Install]
WantedBy=multi-user.target
SVC

    sudo systemctl daemon-reload
    sudo systemctl enable vector
    sudo systemctl start vector

    echo -e "${GREEN}Vector installed as systemd service${NC}"
    echo -e "${YELLOW}Check status: systemctl status vector${NC}"
fi

echo ""
echo -e "${GREEN}Vector installed successfully!${NC}"
echo -e "Config: /etc/vector/vector.toml"
echo -e "Sending logs to: ${CLICKHOUSE_URL:-$PURL_API_URL}"
