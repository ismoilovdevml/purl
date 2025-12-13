#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PURL_VERSION="latest"
INSTALL_DIR="/opt/purl"
CONFIG_DIR="/etc/purl"
DATA_DIR="/var/lib/purl"
INTERACTIVE=false

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
  ____            _
 |  _ \ _   _ _ _| |
 | |_) | | | | '_| |
 |  __/| |_| | | | |
 |_|    \__,_|_| |_|
EOF
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} ${BOLD}$1${NC}"; }

prompt() {
    local message="$1" default="$2" result
    if [ "$INTERACTIVE" = true ]; then
        if [ -n "$default" ]; then
            echo -en "${CYAN}$message${NC} [${default}]: " > /dev/tty
            read result < /dev/tty
            echo "${result:-$default}"
        else
            echo -en "${CYAN}$message${NC}: " > /dev/tty
            read result < /dev/tty
            echo "$result"
        fi
    else
        echo "$default"
    fi
}

prompt_password() {
    local message="$1" default="$2" result
    if [ "$INTERACTIVE" = true ]; then
        echo -en "${CYAN}$message${NC}: " > /dev/tty
        read -s result < /dev/tty
        echo > /dev/tty
        echo "${result:-$default}"
    else
        echo "$default"
    fi
}

prompt_yes_no() {
    local message="$1" default="${2:-y}" result
    if [ "$INTERACTIVE" = true ]; then
        if [ "$default" = "y" ]; then
            echo -en "${CYAN}$message${NC} [Y/n]: " > /dev/tty
        else
            echo -en "${CYAN}$message${NC} [y/N]: " > /dev/tty
        fi
        read result < /dev/tty
        result="${result:-$default}"
        [[ "$result" =~ ^[Yy] ]]
    else
        [ "$default" = "y" ]
    fi
}

generate_password() { openssl rand -base64 "${1:-24}" | tr -d '/+=' | head -c "${1:-24}"; }
generate_api_key() { openssl rand -base64 32 | tr -d '/+='; }

get_ip_address() {
    local ip=""
    if command -v ip &> /dev/null; then
        ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    fi
    if [ -z "$ip" ] && command -v hostname &> /dev/null; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$ip" ]; then
        ip=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}')
    fi
    echo "${ip:-localhost}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        log_info "Detected OS: $OS $OS_VERSION"
    else
        log_error "Cannot detect OS"
        exit 1
    fi
}

check_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker found: $(docker --version | cut -d' ' -f3 | tr -d ',')"
        if ! docker compose version &> /dev/null; then
            log_error "Docker Compose plugin not found"
            return 1
        fi
        return 0
    fi
    return 1
}

check_systemd() {
    command -v systemctl &> /dev/null && [ -d /run/systemd/system ]
}

check_curl() {
    command -v curl &> /dev/null || { log_error "curl is required"; exit 1; }
}

check_openssl() {
    command -v openssl &> /dev/null || { log_error "openssl is required"; exit 1; }
}

install_purl_docker() {
    log_step "Installing Purl with Docker..."
    local install_path="${1:-/opt/purl}"

    mkdir -p "$install_path" "$install_path/config" "$install_path/docker/clickhouse"
    cd "$install_path"

    log_info "Downloading configuration files..."
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker-compose.yml" -o docker-compose.yml
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker/clickhouse/config.xml" -o docker/clickhouse/config.xml
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker/clickhouse/users.xml" -o docker/clickhouse/users.xml
    mkdir -p deploy/vector
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/deploy/vector/vector.toml" -o deploy/vector/vector.toml

    local ch_password=$(generate_password 24)
    local api_key=$(generate_api_key)
    local purl_port="3000"
    local retention_days="30"

    if [ "$INTERACTIVE" = true ]; then
        echo
        log_step "Configuration"
        ch_password=$(prompt "ClickHouse password" "$ch_password")
        api_key=$(prompt "API Key" "$api_key")
        purl_port=$(prompt "Purl port" "$purl_port")
        retention_days=$(prompt "Log retention (days)" "$retention_days")
    fi

    cat > .env << EOF
PURL_PORT=$purl_port
PURL_HOST=0.0.0.0
PURL_STORAGE_TYPE=clickhouse
PURL_CLICKHOUSE_HOST=clickhouse
PURL_CLICKHOUSE_PORT=8123
PURL_CLICKHOUSE_DATABASE=purl
PURL_CLICKHOUSE_USER=purl
PURL_CLICKHOUSE_PASSWORD=$ch_password
PURL_AUTH_ENABLED=1
PURL_API_KEYS=$api_key
PURL_RETENTION_DAYS=$retention_days
VECTOR_HOSTNAME=$(hostname)
EOF

    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/CHANGE_ME_GENERATE_SECURE_PASSWORD/$ch_password/g" docker/clickhouse/users.xml
    else
        sed -i "s/CHANGE_ME_GENERATE_SECURE_PASSWORD/$ch_password/g" docker/clickhouse/users.xml
    fi

    local INSTALL_VECTOR=false
    prompt_yes_no "Install Vector log collector?" "y" && INSTALL_VECTOR=true

    log_step "Starting Purl services..."
    if [ "$INSTALL_VECTOR" = true ]; then
        docker compose --profile vector up -d
    else
        docker compose up -d
    fi

    log_info "Waiting for services..."
    sleep 10
    local retries=30
    while [ $retries -gt 0 ]; do
        curl -sf http://localhost:$purl_port/api/health > /dev/null 2>&1 && break
        sleep 2
        ((retries--))
    done

    [ $retries -eq 0 ] && log_warn "Health check timed out" || log_info "Purl is healthy!"

    local server_ip=$(get_ip_address)
    cat > "$install_path/.credentials" << EOF
PURL_URL=http://$server_ip:$purl_port
API_KEY=$api_key
CLICKHOUSE_PASSWORD=$ch_password
EOF
    chmod 600 "$install_path/.credentials"

    echo
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   Purl Installation Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo
    echo -e "${BOLD}Dashboard:${NC} http://$server_ip:$purl_port"
    echo -e "${BOLD}API Key:${NC} $api_key"
    echo
    echo -e "${BOLD}Remote agents:${NC}"
    echo -e "  PURL_URL=http://$server_ip:$purl_port"
    echo -e "  PURL_API_KEY=$api_key"
    echo
    echo -e "${YELLOW}Credentials: $install_path/.credentials${NC}"
    echo
}

install_purl_systemd() {
    log_step "Installing Purl with Systemd..."
    log_warn "Requires: Perl 5.38+, ClickHouse, Node.js 20+"

    prompt_yes_no "Continue?" "n" || exit 0

    local install_path="/opt/purl"
    git clone https://github.com/ismoilovdevml/purl.git "$install_path" || { log_error "Clone failed"; exit 1; }
    cd "$install_path"

    log_info "Installing dependencies..."
    cpanm --installdeps . || log_warn "Some modules failed"
    cd web && npm install && npm run build && cd ..

    if prompt_yes_no "Existing ClickHouse?" "n"; then
        local ch_host=$(prompt "ClickHouse host" "localhost")
        local ch_port=$(prompt "ClickHouse port" "8123")
        local ch_user=$(prompt "ClickHouse user" "purl")
        local ch_pass=$(prompt_password "ClickHouse password")
    else
        log_info "Install ClickHouse first"
        exit 1
    fi

    local api_key=$(generate_api_key)
    local purl_port=$(prompt "Purl port" "3000")

    mkdir -p /etc/purl
    cat > /etc/purl/purl.env << EOF
PURL_PORT=$purl_port
PURL_HOST=0.0.0.0
PURL_STORAGE_TYPE=clickhouse
PURL_CLICKHOUSE_HOST=$ch_host
PURL_CLICKHOUSE_PORT=$ch_port
PURL_CLICKHOUSE_DATABASE=purl
PURL_CLICKHOUSE_USER=$ch_user
PURL_CLICKHOUSE_PASSWORD=$ch_pass
PURL_AUTH_ENABLED=1
PURL_API_KEYS=$api_key
PURL_RETENTION_DAYS=30
EOF
    chmod 600 /etc/purl/purl.env

    cat > /etc/systemd/system/purl.service << 'EOF'
[Unit]
Description=Purl Log Dashboard
After=network.target clickhouse-server.service

[Service]
Type=simple
EnvironmentFile=/etc/purl/purl.env
WorkingDirectory=/opt/purl
ExecStart=/usr/bin/perl -I/opt/purl/lib -MPurl::API::Server -e 'Purl::API::Server->create->run'
Restart=always
RestartSec=5
User=purl
Group=purl

[Install]
WantedBy=multi-user.target
EOF

    useradd -r -s /bin/false purl 2>/dev/null || true
    chown -R purl:purl "$install_path"
    systemctl daemon-reload
    systemctl enable --now purl

    local server_ip=$(get_ip_address)
    echo
    echo -e "${GREEN}Purl installed!${NC}"
    echo -e "${BOLD}Dashboard:${NC} http://$server_ip:$purl_port"
    echo -e "${BOLD}API Key:${NC} $api_key"
    echo
}

install_agent() {
    print_banner
    log_step "Installing Vector Agent"

    local purl_url=$(prompt "Purl server URL")
    local api_key=$(prompt "API Key")

    [ -z "$purl_url" ] || [ -z "$api_key" ] && { log_error "URL and API Key required"; exit 1; }

    log_info "Testing connection..."
    curl -sf -H "X-API-Key: $api_key" "$purl_url/api/health" > /dev/null 2>&1 \
        && log_info "Connected!" || log_warn "Connection failed, continuing..."

    echo
    echo -e "${BOLD}Method:${NC} 1) Docker  2) Binary"
    local method=$(prompt "Choose [1/2]" "1")
    local hostname_label=$(prompt "Hostname" "$(hostname)")

    local has_journald=false
    command -v journalctl &> /dev/null && has_journald=true

    mkdir -p /etc/vector
    cat > /etc/vector/vector.toml << EOF
data_dir = "/var/lib/vector"

[api]
enabled = true
address = "0.0.0.0:8686"

[sources.docker_logs]
type = "docker_logs"
docker_host = "unix:///var/run/docker.sock"
exclude_containers = ["vector", "*-vector"]
EOF

    if [ "$has_journald" = true ]; then
        cat >> /etc/vector/vector.toml << 'EOF'

[sources.journald]
type = "journald"
current_boot_only = true
exclude_units = ["vector.service"]
EOF
    fi

    local inputs="docker_logs"
    [ "$has_journald" = true ] && inputs="docker_logs, journald"

    cat >> /etc/vector/vector.toml << EOF

[transforms.parsed]
type = "remap"
inputs = ["$inputs"]
source = '''
.host = "$hostname_label"
service_name = string(.container_name) ?? string(._SYSTEMD_UNIT) ?? "unknown"
.service = replace(replace(service_name, r'^/', ""), r'\.service$', "")

msg = string(.message) ?? ""
.raw = msg

if match(msg, r'(?i)\b(fatal|panic|critical)\b') { .level = "FATAL" }
else if match(msg, r'(?i)\b(error|err|exception|failed)\b') { .level = "ERROR" }
else if match(msg, r'(?i)\b(warn|warning)\b') { .level = "WARN" }
else if match(msg, r'(?i)\b(debug|trace)\b') { .level = "DEBUG" }
else { .level = "INFO" }

.meta = encode_json({"source": "vector-agent", "server": .host})
del(.container_id); del(.container_name); del(._SYSTEMD_UNIT); del(.PRIORITY); del(._PID)
'''

[transforms.filtered]
type = "filter"
inputs = ["parsed"]
condition = 'length(string!(.message)) > 0 && !starts_with(string!(.message), "vector::")'

[sinks.purl]
type = "http"
inputs = ["filtered"]
uri = "$purl_url/api/logs"
method = "post"
compression = "gzip"

[sinks.purl.encoding]
codec = "json"

[sinks.purl.batch]
max_bytes = 1048576
max_events = 100
timeout_secs = 5

[sinks.purl.buffer]
type = "disk"
max_size = 268435488
when_full = "block"

[sinks.purl.request]
concurrency = 10
timeout_secs = 30
headers.Content-Type = "application/json"
headers.X-API-Key = "$api_key"
EOF

    if [ "$method" = "1" ]; then
        log_step "Installing via Docker..."
        docker rm -f purl-vector 2>/dev/null || true
        docker run -d --name purl-vector --restart unless-stopped \
            -v /etc/vector:/etc/vector:ro \
            -v /var/run/docker.sock:/var/run/docker.sock:ro \
            -v /var/log:/var/log:ro \
            -v purl-vector-data:/var/lib/vector \
            timberio/vector:0.51.1-alpine --config /etc/vector/vector.toml

        echo -e "\n${GREEN}Vector agent installed!${NC}"
        echo -e "Logs: docker logs -f purl-vector"
    else
        log_step "Installing binary..."
        curl -fsSL https://sh.vector.dev | bash -s -- -y

        cat > /etc/systemd/system/vector.service << 'EOF'
[Unit]
Description=Vector Log Collector
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/vector --config /etc/vector/vector.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now vector

        echo -e "\n${GREEN}Vector agent installed!${NC}"
        echo -e "Status: systemctl status vector"
    fi
}

main() {
    INSTALL_AGENT=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --agent|-a) INSTALL_AGENT=true; shift ;;
            --interactive|-i) INTERACTIVE=true; shift ;;
            --help|-h)
                echo "Usage: $0 [--agent] [--interactive]"
                echo "  --agent, -a        Install Vector agent only"
                echo "  --interactive, -i  Enable prompts"
                exit 0 ;;
            *) shift ;;
        esac
    done

    print_banner

    if [ "$INSTALL_AGENT" = true ]; then
        [ "$INTERACTIVE" = false ] && { log_error "Agent requires -i flag"; exit 1; }
        check_root
        check_curl
        install_agent
        exit 0
    fi

    check_root
    check_os
    check_curl
    check_openssl

    local choice="1"
    if [ "$INTERACTIVE" = true ]; then
        echo -e "${BOLD}Install:${NC} 1) Docker  2) Systemd  3) Agent only"
        choice=$(prompt "Choose [1/2/3]" "1")
    fi

    case $choice in
        1)
            check_docker || { log_error "Docker required: curl -fsSL https://get.docker.com | sh"; exit 1; }
            install_purl_docker ;;
        2)
            check_systemd || { log_error "Systemd not found"; exit 1; }
            install_purl_systemd ;;
        3) install_agent ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
}

main "$@"
