#!/bin/bash
set -e

# ============================================
# Purl Unified Installer
# Logs + Traces + Auto-Discovery
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PURL_VERSION="latest"
BEYLA_VERSION="2.8.2"
VECTOR_VERSION="0.51.1"
INSTALL_DIR="/opt/purl"

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
  ____            _
 |  _ \ _   _ _ _| |
 | |_) | | | | '_| |
 |  __/| |_| | | | |
 |_|    \__,_|_| |_|

 Unified Observability Platform
 Logs • Traces • Auto-Discovery
EOF
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}==>${NC} ${BOLD}$1${NC}"; }

prompt() {
    local message="$1" default="$2" result
    if [ -n "$default" ]; then
        echo -en "${CYAN}$message${NC} [${default}]: " > /dev/tty
        read result < /dev/tty
        echo "${result:-$default}"
    else
        echo -en "${CYAN}$message${NC}: " > /dev/tty
        read result < /dev/tty
        echo "$result"
    fi
}

prompt_yes_no() {
    local message="$1" default="${2:-y}" result
    if [ "$default" = "y" ]; then
        echo -en "${CYAN}$message${NC} [Y/n]: " > /dev/tty
    else
        echo -en "${CYAN}$message${NC} [y/N]: " > /dev/tty
    fi
    read result < /dev/tty
    result="${result:-$default}"
    [[ "$result" =~ ^[Yy] ]]
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

check_docker() {
    if command -v docker &> /dev/null; then
        if ! docker compose version &> /dev/null; then
            log_error "Docker Compose plugin not found"
            return 1
        fi
        return 0
    fi
    return 1
}

check_kernel_btf() {
    # Check BTF support for Beyla eBPF
    if [ -f /sys/kernel/btf/vmlinux ]; then
        return 0
    fi
    return 1
}

check_kernel_version() {
    local kernel_version=$(uname -r | cut -d. -f1-2)
    local major=$(echo $kernel_version | cut -d. -f1)
    local minor=$(echo $kernel_version | cut -d. -f2)

    # Need kernel 5.8+
    if [ "$major" -gt 5 ] || ([ "$major" -eq 5 ] && [ "$minor" -ge 8 ]); then
        return 0
    fi
    return 1
}

# ============================================
# Install Purl Server (Full Stack)
# ============================================
install_purl_server() {
    log_step "Installing Purl Server..."
    local install_path="${1:-$INSTALL_DIR}"

    mkdir -p "$install_path" "$install_path/config" "$install_path/docker/clickhouse" "$install_path/deploy/vector" "$install_path/deploy/beyla"
    cd "$install_path"

    log_info "Downloading configuration files..."

    # Core files
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker-compose.yml" -o docker-compose.yml
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker/clickhouse/config.xml" -o docker/clickhouse/config.xml
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/docker/clickhouse/users.xml" -o docker/clickhouse/users.xml

    # Vector config
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/deploy/vector/vector.toml" -o deploy/vector/vector.toml

    # Beyla config
    curl -fsSL "https://raw.githubusercontent.com/ismoilovdevml/purl/main/deploy/beyla/docker-compose.beyla.yml" -o deploy/beyla/docker-compose.beyla.yml

    # Generate secure credentials
    local ch_password=$(generate_password 24)
    local api_key=$(generate_api_key)
    local purl_port="3000"
    local retention_days="30"

    if [ "$INTERACTIVE" = true ]; then
        echo
        log_step "Configuration"
        purl_port=$(prompt "Purl port" "$purl_port")
        retention_days=$(prompt "Log retention (days)" "$retention_days")
    fi

    # Create .env file
    cat > .env << EOF
# Purl Configuration
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

# Vector Configuration
VECTOR_HOSTNAME=$(hostname)

# Beyla Configuration
PURL_OTLP_ENDPOINT=http://localhost:$purl_port
ENVIRONMENT=production
BEYLA_LOG_LEVEL=INFO
EOF

    # Update ClickHouse password
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/CHANGE_ME_GENERATE_SECURE_PASSWORD/$ch_password/g" docker/clickhouse/users.xml
    else
        sed -i "s/CHANGE_ME_GENERATE_SECURE_PASSWORD/$ch_password/g" docker/clickhouse/users.xml
    fi

    # Ask what to install
    local INSTALL_VECTOR=false
    local INSTALL_BEYLA=false

    if [ "$INTERACTIVE" = true ]; then
        echo
        prompt_yes_no "Install Vector (log collection from Docker/systemd)?" "y" && INSTALL_VECTOR=true

        if check_kernel_btf && check_kernel_version; then
            prompt_yes_no "Install Beyla (auto-tracing with eBPF)?" "y" && INSTALL_BEYLA=true
        else
            log_warn "Beyla requires Linux kernel 5.8+ with BTF. Skipping..."
        fi
    else
        # Non-interactive: install everything if possible
        INSTALL_VECTOR=true
        check_kernel_btf && check_kernel_version && INSTALL_BEYLA=true
    fi

    # Start services
    log_step "Starting Purl services..."

    if [ "$INSTALL_VECTOR" = true ]; then
        docker compose --profile vector up -d
    else
        docker compose up -d
    fi

    # Wait for Purl to be healthy
    log_info "Waiting for Purl to start..."
    sleep 10
    local retries=30
    while [ $retries -gt 0 ]; do
        curl -sf http://localhost:$purl_port/api/health > /dev/null 2>&1 && break
        sleep 2
        ((retries--))
    done

    if [ $retries -eq 0 ]; then
        log_warn "Health check timed out"
    else
        log_info "Purl is healthy!"
    fi

    # Start Beyla if requested
    if [ "$INSTALL_BEYLA" = true ]; then
        log_step "Starting Beyla auto-tracing..."
        docker compose -f deploy/beyla/docker-compose.beyla.yml up -d
        log_info "Beyla started with auto-discovery"
    fi

    # Save credentials
    local server_ip=$(get_ip_address)
    cat > "$install_path/.credentials" << EOF
PURL_URL=http://$server_ip:$purl_port
API_KEY=$api_key
CLICKHOUSE_PASSWORD=$ch_password
EOF
    chmod 600 "$install_path/.credentials"

    # Print success message
    echo
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}║   ${BOLD}Purl Installation Complete!${NC}${GREEN}                            ║${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Dashboard:${NC}   http://$server_ip:$purl_port"
    echo -e "${BOLD}API Key:${NC}     $api_key"
    echo
    echo -e "${BOLD}Installed components:${NC}"
    echo -e "  ✓ Purl Server"
    echo -e "  ✓ ClickHouse Database"
    [ "$INSTALL_VECTOR" = true ] && echo -e "  ✓ Vector Log Collector"
    [ "$INSTALL_BEYLA" = true ] && echo -e "  ✓ Beyla Auto-Tracing (eBPF)"
    echo
    if [ "$INSTALL_BEYLA" = true ]; then
        echo -e "${CYAN}Auto-tracing is enabled!${NC}"
        echo -e "All HTTP/gRPC applications will be automatically traced."
        echo
    fi
    echo -e "${BOLD}For remote agents:${NC}"
    echo -e "  curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | sudo bash -s -- --agent"
    echo
    echo -e "${YELLOW}Credentials saved: $install_path/.credentials${NC}"
    echo
}

# ============================================
# Install Agent (Vector + Beyla)
# ============================================
install_agent() {
    print_banner
    log_step "Installing Purl Agent (Logs + Traces)"

    local purl_url=$(prompt "Purl server URL (e.g., http://192.168.1.100:3000)")
    local api_key=$(prompt "API Key")

    [ -z "$purl_url" ] || [ -z "$api_key" ] && { log_error "URL and API Key required"; exit 1; }

    # Test connection
    log_info "Testing connection..."
    if curl -sf -H "X-API-Key: $api_key" "$purl_url/api/health" > /dev/null 2>&1; then
        log_info "Connection successful!"
    else
        log_warn "Connection failed. Continuing anyway..."
    fi

    local hostname_label=$(prompt "Hostname label" "$(hostname)")

    # Ask what to install
    local INSTALL_VECTOR=true
    local INSTALL_BEYLA=false

    if check_kernel_btf && check_kernel_version; then
        prompt_yes_no "Install Beyla (auto-tracing)?" "y" && INSTALL_BEYLA=true
    else
        log_warn "Beyla requires Linux kernel 5.8+ with BTF"
    fi

    # Install Vector
    if [ "$INSTALL_VECTOR" = true ]; then
        install_vector_agent "$purl_url" "$api_key" "$hostname_label"
    fi

    # Install Beyla
    if [ "$INSTALL_BEYLA" = true ]; then
        install_beyla_agent "$purl_url" "$hostname_label"
    fi

    echo
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ${BOLD}Agent Installation Complete!${NC}${GREEN}                            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Installed:${NC}"
    [ "$INSTALL_VECTOR" = true ] && echo -e "  ✓ Vector (logs) → $purl_url"
    [ "$INSTALL_BEYLA" = true ] && echo -e "  ✓ Beyla (traces) → $purl_url"
    echo
    echo -e "${BOLD}Check status:${NC}"
    [ "$INSTALL_VECTOR" = true ] && echo -e "  docker logs -f purl-vector"
    [ "$INSTALL_BEYLA" = true ] && echo -e "  docker logs -f purl-beyla"
    echo
}

install_vector_agent() {
    local purl_url="$1"
    local api_key="$2"
    local hostname_label="$3"

    log_step "Installing Vector agent..."

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
exclude_containers = ["vector", "*-vector", "purl", "beyla", "*-beyla"]
EOF

    if [ "$has_journald" = true ]; then
        cat >> /etc/vector/vector.toml << 'EOF'

[sources.journald]
type = "journald"
current_boot_only = true
exclude_units = ["vector.service"]
EOF
    fi

    local inputs='["docker_logs"]'
    [ "$has_journald" = true ] && inputs='["docker_logs", "journald"]'

    cat >> /etc/vector/vector.toml << EOF

[transforms.parsed]
type = "remap"
inputs = $inputs
source = '''
.host = "$hostname_label"
service_name = string(.container_name) ?? string(._SYSTEMD_UNIT) ?? "unknown"
.service = replace(replace(service_name, r'^/', ""), r'\.service\$', "")

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

    # Run Vector in Docker
    docker rm -f purl-vector 2>/dev/null || true
    docker run -d \
        --name purl-vector \
        --restart unless-stopped \
        -v /etc/vector:/etc/vector:ro \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v /var/log:/var/log:ro \
        -v purl-vector-data:/var/lib/vector \
        timberio/vector:$VECTOR_VERSION-alpine \
        --config /etc/vector/vector.toml

    log_info "Vector agent started"
}

install_beyla_agent() {
    local purl_url="$1"
    local hostname_label="$2"

    log_step "Installing Beyla auto-tracing agent..."

    # Run Beyla in Docker with auto-discovery
    docker rm -f purl-beyla 2>/dev/null || true
    docker run -d \
        --name purl-beyla \
        --restart unless-stopped \
        --privileged \
        --pid host \
        --network host \
        -e "BEYLA_DISCOVERY_SERVICES=.*" \
        -e "OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf" \
        -e "OTEL_EXPORTER_OTLP_ENDPOINT=$purl_url" \
        -e "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=$purl_url/v1/traces" \
        -e "OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,host.name=$hostname_label" \
        -e "BEYLA_LOG_LEVEL=INFO" \
        -e "BEYLA_EBPF_TRACK_REQUEST_HEADERS=true" \
        -e "BEYLA_INTERNAL_METRICS_PROMETHEUS_PORT=6060" \
        -v /sys/kernel/debug:/sys/kernel/debug:ro \
        -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
        -v /sys/fs/bpf:/sys/fs/bpf:rw \
        grafana/beyla:$BEYLA_VERSION

    log_info "Beyla agent started with auto-discovery"
}

# ============================================
# Uninstall
# ============================================
uninstall() {
    log_step "Uninstalling Purl..."

    # Stop and remove containers
    docker rm -f purl purl-local purl-clickhouse purl-clickhouse-local purl-vector purl-vector-local purl-beyla 2>/dev/null || true

    # Remove volumes
    prompt_yes_no "Remove data volumes?" "n" && {
        docker volume rm clickhouse_data clickhouse_logs clickhouse_data_local clickhouse_logs_local purl-vector-data 2>/dev/null || true
    }

    # Remove config
    prompt_yes_no "Remove config files?" "n" && {
        rm -rf /opt/purl /etc/vector/vector.toml
    }

    log_info "Uninstall complete"
}

# ============================================
# Status check
# ============================================
status() {
    echo -e "${BOLD}Purl Services Status:${NC}"
    echo
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" --filter "name=purl" --filter "name=clickhouse" --filter "name=vector" --filter "name=beyla" 2>/dev/null || echo "No containers found"
    echo
}

# ============================================
# Main
# ============================================
main() {
    INTERACTIVE=true
    local MODE="server"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --agent|-a) MODE="agent"; shift ;;
            --server|-s) MODE="server"; shift ;;
            --uninstall|-u) MODE="uninstall"; shift ;;
            --status) MODE="status"; shift ;;
            --non-interactive|-y) INTERACTIVE=false; shift ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo
                echo "Options:"
                echo "  --server, -s         Install Purl server (default)"
                echo "  --agent, -a          Install agent only (Vector + Beyla)"
                echo "  --uninstall, -u      Remove Purl"
                echo "  --status             Show service status"
                echo "  --non-interactive, -y  Don't ask for confirmation"
                echo "  --help, -h           Show this help"
                echo
                echo "Examples:"
                echo "  # Install server with all components"
                echo "  curl -fsSL https://purl.dev/install.sh | sudo bash"
                echo
                echo "  # Install agent on remote server"
                echo "  curl -fsSL https://purl.dev/install.sh | sudo bash -s -- --agent"
                echo
                exit 0 ;;
            *) shift ;;
        esac
    done

    print_banner

    case $MODE in
        server)
            check_root
            check_docker || {
                log_error "Docker is required. Install with: curl -fsSL https://get.docker.com | sh"
                exit 1
            }
            install_purl_server
            ;;
        agent)
            check_root
            check_docker || {
                log_error "Docker is required. Install with: curl -fsSL https://get.docker.com | sh"
                exit 1
            }
            install_agent
            ;;
        uninstall)
            check_root
            uninstall
            ;;
        status)
            status
            ;;
    esac
}

main "$@"
