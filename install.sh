#!/bin/bash
# =============================================================================
# Purl Installation Script
# =============================================================================
# Usage: curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | bash
# Or: curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | bash -s -- --agent
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
PURL_VERSION="latest"
INSTALL_DIR="/opt/purl"
CONFIG_DIR="/etc/purl"
DATA_DIR="/var/lib/purl"

# =============================================================================
# Helper Functions
# =============================================================================

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
  ____            _
 |  _ \ _   _ _ _| |
 | |_) | | | | '_| |
 |  __/| |_| | | | |
 |_|    \__,_|_| |_|

 Log Aggregation Dashboard
EOF
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} ${BOLD}$1${NC}"; }

prompt() {
    local message="$1"
    local default="$2"
    local result

    if [ -n "$default" ]; then
        read -p "$(echo -e "${CYAN}$message${NC} [${default}]: ")" result
        echo "${result:-$default}"
    else
        read -p "$(echo -e "${CYAN}$message${NC}: ")" result
        echo "$result"
    fi
}

prompt_password() {
    local message="$1"
    local result
    read -sp "$(echo -e "${CYAN}$message${NC}: ")" result
    echo
    echo "$result"
}

prompt_yes_no() {
    local message="$1"
    local default="${2:-y}"
    local result

    if [ "$default" = "y" ]; then
        read -p "$(echo -e "${CYAN}$message${NC} [Y/n]: ")" result
        result="${result:-y}"
    else
        read -p "$(echo -e "${CYAN}$message${NC} [y/N]: ")" result
        result="${result:-n}"
    fi

    [[ "$result" =~ ^[Yy] ]]
}

generate_password() {
    openssl rand -base64 "${1:-24}" | tr -d '/+=' | head -c "${1:-24}"
}

generate_api_key() {
    openssl rand -base64 32 | tr -d '/+='
}

# =============================================================================
# Requirement Checks
# =============================================================================

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
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    case "$OS" in
        ubuntu|debian|centos|rhel|rocky|almalinux|fedora|amzn)
            log_info "Detected OS: $OS $OS_VERSION"
            ;;
        *)
            log_warn "Untested OS: $OS. Proceeding anyway..."
            ;;
    esac
}

check_docker() {
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
        log_info "Docker found: $DOCKER_VERSION"

        if ! docker compose version &> /dev/null; then
            log_error "Docker Compose plugin not found. Please install: docker compose"
            return 1
        fi
        return 0
    fi
    return 1
}

check_systemd() {
    if command -v systemctl &> /dev/null && [ -d /run/systemd/system ]; then
        log_info "Systemd found"
        return 0
    fi
    return 1
}

check_curl() {
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        exit 1
    fi
}

check_openssl() {
    if ! command -v openssl &> /dev/null; then
        log_error "openssl is required but not installed"
        exit 1
    fi
}

install_docker() {
    log_step "Installing Docker..."

    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker

    log_info "Docker installed successfully"
}

# =============================================================================
# Installation Functions
# =============================================================================

install_purl_docker() {
    log_step "Installing Purl with Docker..."

    local install_path="${1:-/opt/purl}"

    # Create directories
    mkdir -p "$install_path" "$install_path/config" "$install_path/docker/clickhouse"
    cd "$install_path"

    # Download docker-compose.yml
    log_info "Downloading configuration files..."
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker-compose.yml" -o docker-compose.yml
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker/clickhouse/config.xml" -o docker/clickhouse/config.xml
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker/clickhouse/users.xml" -o docker/clickhouse/users.xml
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/deploy/vector/vector.toml" -o vector.toml
    mkdir -p deploy/vector && mv vector.toml deploy/vector/

    # Generate credentials
    local ch_password=$(generate_password 24)
    local api_key=$(generate_api_key)

    # Ask for custom values or use generated
    echo
    log_step "Configuration"
    echo -e "${YELLOW}Leave blank to use auto-generated secure values${NC}"
    echo

    local custom_ch_pass=$(prompt "ClickHouse password" "$ch_password")
    local custom_api_key=$(prompt "API Key" "$api_key")
    local purl_port=$(prompt "Purl port" "3000")
    local retention_days=$(prompt "Log retention (days)" "30")

    ch_password="${custom_ch_pass:-$ch_password}"
    api_key="${custom_api_key:-$api_key}"

    # Create .env file
    cat > .env << EOF
# Purl Configuration - Generated by install.sh
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
EOF

    # Update ClickHouse users.xml with password
    sed -i "s/CHANGE_ME_GENERATE_SECURE_PASSWORD/$ch_password/g" docker/clickhouse/users.xml

    # Ask about Vector
    echo
    if prompt_yes_no "Install Vector log collector?" "y"; then
        INSTALL_VECTOR=true
    else
        INSTALL_VECTOR=false
    fi

    # Pull and start
    log_step "Starting Purl services..."

    if [ "$INSTALL_VECTOR" = true ]; then
        docker compose --profile vector up -d
    else
        docker compose up -d
    fi

    # Wait for health
    log_info "Waiting for services to be healthy..."
    sleep 10

    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -sf http://localhost:$purl_port/api/health > /dev/null 2>&1; then
            break
        fi
        sleep 2
        ((retries--))
    done

    if [ $retries -eq 0 ]; then
        log_warn "Health check timed out. Check logs: docker compose logs"
    else
        log_info "Purl is healthy!"
    fi

    # Save credentials
    cat > "$install_path/.credentials" << EOF
# Purl Credentials - KEEP THIS SECURE!
# Generated: $(date)

PURL_URL=http://$(hostname -I | awk '{print $1}'):$purl_port
API_KEY=$api_key
CLICKHOUSE_PASSWORD=$ch_password
EOF
    chmod 600 "$install_path/.credentials"

    # Print summary
    echo
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   Purl Installation Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo
    echo -e "${BOLD}Dashboard URL:${NC} http://$(hostname -I | awk '{print $1}'):$purl_port"
    echo
    echo -e "${BOLD}Credentials (save these!):${NC}"
    echo -e "  API Key: ${CYAN}$api_key${NC}"
    echo -e "  ClickHouse Password: ${CYAN}$ch_password${NC}"
    echo
    echo -e "${BOLD}For remote Vector agents, use:${NC}"
    echo -e "  PURL_URL=http://$(hostname -I | awk '{print $1}'):$purl_port"
    echo -e "  PURL_API_KEY=$api_key"
    echo
    echo -e "${YELLOW}Credentials saved to: $install_path/.credentials${NC}"
    echo
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  View logs:    cd $install_path && docker compose logs -f"
    echo -e "  Stop:         cd $install_path && docker compose down"
    echo -e "  Start:        cd $install_path && docker compose up -d"
    echo
}

install_purl_systemd() {
    log_step "Installing Purl with Systemd..."

    log_warn "Systemd installation requires:"
    log_warn "  - Perl 5.38+ with Mojolicious"
    log_warn "  - ClickHouse server"
    log_warn "  - Node.js 20+ for web build"
    echo

    if ! prompt_yes_no "Continue with systemd installation?" "n"; then
        log_info "Aborted. Consider Docker installation instead."
        exit 0
    fi

    local install_path="/opt/purl"

    # Clone repository
    log_info "Cloning Purl repository..."
    git clone https://github.com/ismoilovdevml/purl.git "$install_path" || {
        log_error "Failed to clone repository"
        exit 1
    }

    cd "$install_path"

    # Install Perl dependencies
    log_info "Installing Perl dependencies..."
    cpanm --installdeps . || {
        log_warn "Some Perl modules failed. You may need to install them manually."
    }

    # Build web assets
    log_info "Building web assets..."
    cd web && npm install && npm run build
    cd ..

    # Setup ClickHouse
    echo
    if prompt_yes_no "Do you have existing ClickHouse?" "n"; then
        local ch_host=$(prompt "ClickHouse host" "localhost")
        local ch_port=$(prompt "ClickHouse port" "8123")
        local ch_user=$(prompt "ClickHouse user" "purl")
        local ch_pass=$(prompt_password "ClickHouse password")
    else
        log_info "Please install ClickHouse first:"
        echo "  Ubuntu/Debian: apt install clickhouse-server"
        echo "  RHEL/CentOS: yum install clickhouse-server"
        exit 1
    fi

    local api_key=$(generate_api_key)
    local purl_port=$(prompt "Purl port" "3000")

    # Create config
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

    # Create systemd service
    cat > /etc/systemd/system/purl.service << 'EOF'
[Unit]
Description=Purl Log Dashboard
After=network.target clickhouse-server.service

[Service]
Type=simple
EnvironmentFile=/etc/purl/purl.env
WorkingDirectory=/opt/purl
ExecStart=/usr/bin/perl -I/opt/purl/lib -MPurl::API::Server -e 'Purl::API::Server->new->run'
Restart=always
RestartSec=5
User=purl
Group=purl

[Install]
WantedBy=multi-user.target
EOF

    # Create user
    useradd -r -s /bin/false purl 2>/dev/null || true
    chown -R purl:purl "$install_path"

    # Enable and start
    systemctl daemon-reload
    systemctl enable purl
    systemctl start purl

    # Print summary
    echo
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   Purl Installation Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo
    echo -e "${BOLD}Dashboard URL:${NC} http://$(hostname -I | awk '{print $1}'):$purl_port"
    echo -e "${BOLD}API Key:${NC} $api_key"
    echo
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  Status:  systemctl status purl"
    echo -e "  Logs:    journalctl -u purl -f"
    echo -e "  Restart: systemctl restart purl"
    echo
}

# =============================================================================
# Agent Installation
# =============================================================================

install_agent() {
    print_banner
    log_step "Installing Purl Vector Agent"
    echo

    # Get Purl server details
    local purl_url=$(prompt "Purl server URL (e.g., http://192.168.1.100:3000)")
    local api_key=$(prompt "API Key")

    if [ -z "$purl_url" ] || [ -z "$api_key" ]; then
        log_error "Purl URL and API Key are required"
        exit 1
    fi

    # Test connection
    log_info "Testing connection to Purl server..."
    if ! curl -sf -H "X-API-Key: $api_key" "$purl_url/api/health" > /dev/null 2>&1; then
        log_warn "Could not connect to Purl server. Continuing anyway..."
    else
        log_info "Connection successful!"
    fi

    # Choose installation method
    echo
    echo -e "${BOLD}Installation method:${NC}"
    echo "  1) Docker (recommended)"
    echo "  2) Binary (systemd service)"
    echo
    local method=$(prompt "Choose [1/2]" "1")

    local hostname_label=$(prompt "Server hostname label" "$(hostname)")

    # Create Vector config
    mkdir -p /etc/vector

    cat > /etc/vector/vector.toml << EOF
# Purl Vector Agent - Generated by install.sh
data_dir = "/var/lib/vector"

[api]
enabled = true
address = "0.0.0.0:8686"

# Sources
[sources.docker_logs]
type = "docker_logs"
docker_host = "unix:///var/run/docker.sock"
exclude_containers = ["vector", "*-vector"]

[sources.journald]
type = "journald"
current_boot_only = true
exclude_units = ["vector.service"]

# Transform
[transforms.parsed]
type = "remap"
inputs = ["docker_logs", "journald"]
source = '''
.host = "$hostname_label"
.service = .container_name ?? ._SYSTEMD_UNIT ?? "unknown"
.service = replace(string!(.service), r'^/', "")
.service = replace(string!(.service), r'\.service\$', "")

msg = string(.message) ?? ""
.raw = msg

if match(msg, r'(?i)\b(fatal|panic|critical)\b') {
    .level = "FATAL"
} else if match(msg, r'(?i)\b(error|err|exception|failed)\b') {
    .level = "ERROR"
} else if match(msg, r'(?i)\b(warn|warning)\b') {
    .level = "WARN"
} else if match(msg, r'(?i)\b(debug|trace)\b') {
    .level = "DEBUG"
} else {
    .level = "INFO"
}

.meta = encode_json({
    "source": "vector-agent",
    "server": .host
})

del(.container_id)
del(.container_name)
del(._SYSTEMD_UNIT)
del(.PRIORITY)
del(._PID)
'''

[transforms.filtered]
type = "filter"
inputs = ["parsed"]
condition = 'length(string!(.message)) > 0'

# Sink to Purl
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
        # Docker installation
        log_step "Installing Vector via Docker..."

        docker rm -f purl-vector 2>/dev/null || true

        docker run -d \
            --name purl-vector \
            --restart unless-stopped \
            -v /etc/vector:/etc/vector:ro \
            -v /var/run/docker.sock:/var/run/docker.sock:ro \
            -v /var/log:/var/log:ro \
            -v purl-vector-data:/var/lib/vector \
            timberio/vector:0.51.1-alpine

        log_info "Vector container started"

        echo
        echo -e "${GREEN}============================================${NC}"
        echo -e "${GREEN}   Vector Agent Installation Complete!${NC}"
        echo -e "${GREEN}============================================${NC}"
        echo
        echo -e "${BOLD}Commands:${NC}"
        echo -e "  Logs:    docker logs -f purl-vector"
        echo -e "  Status:  docker ps | grep purl-vector"
        echo -e "  Restart: docker restart purl-vector"
        echo
    else
        # Binary installation
        log_step "Installing Vector binary..."

        curl -fsSL https://sh.vector.dev | bash -s -- -y

        cat > /etc/systemd/system/vector.service << 'EOF'
[Unit]
Description=Vector Log Collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/vector --config /etc/vector/vector.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable vector
        systemctl start vector

        echo
        echo -e "${GREEN}============================================${NC}"
        echo -e "${GREEN}   Vector Agent Installation Complete!${NC}"
        echo -e "${GREEN}============================================${NC}"
        echo
        echo -e "${BOLD}Commands:${NC}"
        echo -e "  Status:  systemctl status vector"
        echo -e "  Logs:    journalctl -u vector -f"
        echo -e "  Restart: systemctl restart vector"
        echo
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_banner

    # Parse arguments
    INSTALL_AGENT=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --agent|-a)
                INSTALL_AGENT=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo
                echo "Options:"
                echo "  --agent, -a    Install Vector agent only"
                echo "  --help, -h     Show this help"
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done

    # Agent installation
    if [ "$INSTALL_AGENT" = true ]; then
        check_root
        check_curl
        install_agent
        exit 0
    fi

    # Full installation
    check_root
    check_os
    check_curl
    check_openssl

    echo
    echo -e "${BOLD}Installation Options:${NC}"
    echo "  1) Docker (recommended)"
    echo "  2) Systemd (bare metal)"
    echo "  3) Agent only (Vector)"
    echo
    local choice=$(prompt "Choose installation type [1/2/3]" "1")

    case $choice in
        1)
            if ! check_docker; then
                if prompt_yes_no "Docker not found. Install Docker?" "y"; then
                    install_docker
                else
                    log_error "Docker is required for this installation type"
                    exit 1
                fi
            fi
            install_purl_docker
            ;;
        2)
            if ! check_systemd; then
                log_error "Systemd not found"
                exit 1
            fi
            install_purl_systemd
            ;;
        3)
            install_agent
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
}

main "$@"
