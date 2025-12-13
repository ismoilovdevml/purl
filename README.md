# Purl

Log aggregation dashboard with ClickHouse. Built with Perl + Svelte.

```text
  ____            _
 |  _ \ _   _ _ _| |
 | |_) | | | | '_| |
 |  __/| |_| | | | |
 |_|    \__,_|_| |_|
```

## Problem

- Logs scattered across multiple Docker containers and services
- No unified search interface
- Kibana/OpenSearch too heavy for small-medium projects
- Need quick log analysis without complex setup

## Solution

Purl provides:

- **Single dashboard** for all logs from any source
- **KQL search** - familiar syntax like `level:ERROR AND service:api*`
- **Live tail** - WebSocket real-time log streaming
- **Saved searches** - save and reuse frequent queries
- **Alerts** - get notified when log patterns match (Telegram/Slack/Webhook)
- **Lightweight** - runs on 512MB RAM
- **Fast** - ClickHouse handles millions of logs

## Architecture

### Single Server (Local Docker)

```text
┌─────────────────────────────────────────────────────────────────┐
│                         PURL SYSTEM                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐ │
│  │   Docker     │     │    Vector    │     │    ClickHouse    │ │
│  │  Containers  │     │              │     │                  │ │
│  │              │────▶│ - Collect    │────▶│ - MergeTree      │ │
│  │ - nginx      │     │ - Transform  │     │ - ZSTD Compress  │ │
│  │ - postgres   │     │ - Buffer     │     │ - TTL Retention  │ │
│  │ - redis      │     │              │     │                  │ │
│  └──────────────┘     └──────────────┘     └────────┬─────────┘ │
│                                                     │           │
│                                                     ▼           │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐ │
│  │  Dashboard   │◀────│  API Server  │◀────│   Storage Layer  │ │
│  │   (Svelte)   │     │ (Mojolicious)│     │                  │ │
│  │              │     │              │     │ - Query Builder  │ │
│  │ - Search     │     │ - REST API   │     │ - Field Stats    │ │
│  │ - Live Tail  │     │ - WebSocket  │     │ - Histogram      │ │
│  │ - Alerts     │     │ - Auth       │     │ - Caching        │ │
│  └──────────────┘     └──────────────┘     └──────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Multi-Server (Centralized Logging)

```text
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│    Server 1     │   │    Server 2     │   │    Server 3     │
│    (Vector)     │   │    (Vector)     │   │    (Vector)     │
└────────┬────────┘   └────────┬────────┘   └────────┬────────┘
         │                     │                     │
         │    HTTPS + API Key  │                     │
         └─────────────────────┼─────────────────────┘
                               ▼
              ┌────────────────────────────────┐
              │      Central Purl Server       │
              │                                │
              │  ┌──────────┐  ┌────────────┐  │
              │  │ Purl API │──│ ClickHouse │  │
              │  │  :3000   │  │   :8123    │  │
              │  └──────────┘  └────────────┘  │
              │                                │
              │  - Authentication (API Key)    │
              │  - Rate Limiting               │
              │  - Input Validation            │
              │  - WebSocket Broadcasting      │
              └────────────────────────────────┘
```

**Why Purl API instead of direct ClickHouse?**

| Feature | Direct ClickHouse | Via Purl API |
|---------|-------------------|--------------|
| Security | Port exposed | API Key auth |
| Rate Limit | None | 1000 req/min |
| Validation | None | Full |
| Real-time | No | WebSocket |

### Kubernetes

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │   Pod: App1 │  │   Pod: App2 │  │   Pod: App3 │  │   Pod: AppN │     │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘     │
│         │                │                │                │            │
│         └────────────────┼────────────────┼────────────────┘            │
│                          ▼                                              │
│         ┌────────────────────────────────────────────────┐              │
│         │        Vector DaemonSet (every node)           │              │
│         │                                                │              │
│         │  - kubernetes_logs source                      │              │
│         │  - Parse & enrich logs                         │              │
│         │  - Disk buffer (survives restarts)             │              │
│         │  - HTTP POST to Purl API                       │              │
│         └────────────────────────┬───────────────────────┘              │
│                                  │                                      │
│                                  ▼                                      │
│         ┌────────────────────────────────────────────────┐              │
│         │           Purl Deployment (2 replicas)         │              │
│         │                                                │              │
│         │  - API Key authentication                      │              │
│         │  - Rate limiting (1000 req/min)                │              │
│         │  - Input validation                            │              │
│         │  - WebSocket live tail broadcast               │              │
│         │  - Graceful shutdown with buffer flush         │              │
│         └────────────────────────┬───────────────────────┘              │
│                                  │                                      │
│                                  ▼                                      │
│         ┌────────────────────────────────────────────────┐              │
│         │         ClickHouse StatefulSet (1 replica)     │              │
│         │                                                │              │
│         │  - MergeTree engine                            │              │
│         │  - ZSTD compression                            │              │
│         │  - TTL-based retention (30 days)               │              │
│         │  - PersistentVolume (10Gi)                     │              │
│         └────────────────────────────────────────────────┘              │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                         Services                                 │   │
│  ├──────────────────────────────────────────────────────────────────┤   │
│  │  purl (ClusterIP:80) ──► Ingress ──► purl.example.com            │   │
│  │  clickhouse (Headless:8123,9000)                                 │   │
│  │  vector (Headless:8686,9598)                                     │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### One-Line Install (Recommended)

```bash
# Install Purl server (Docker)
curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | sudo bash -s -- -i

# Install Vector agent only (for remote servers)
curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | sudo bash -s -- --agent -i
```

The installer will prompt for:
- Installation type (Docker/Systemd/Agent)
- ClickHouse password
- API key
- Port number
- Log retention days
- Vector log collector

### Manual Installation

```bash
git clone https://github.com/ismoilovdevml/purl.git
cd purl

# Copy environment template
cp .env.example .env

# Generate secure credentials
CLICKHOUSE_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
API_KEY=$(openssl rand -base64 32 | tr -d '/+=')

# Update .env with new credentials (Linux)
sed -i "s/CHANGE_ME_GENERATE_SECURE_PASSWORD/$CLICKHOUSE_PASSWORD/" .env
sed -i "s/CHANGE_ME_GENERATE_SECURE_API_KEY/$API_KEY/" .env

# Also update ClickHouse config
sed -i "s/CHANGE_ME_GENERATE_SECURE_PASSWORD/$CLICKHOUSE_PASSWORD/g" docker/clickhouse/users.xml

# macOS users: use sed -i '' instead of sed -i

# Start with auto log collection
docker compose --profile vector up -d

# Open dashboard
open http://localhost:3000

# Show your API key
echo "API Key: $API_KEY"
```

Vector automatically collects logs from **all Docker containers**.

## Deployment Options

### 1. Docker Compose (Recommended for single server)

```bash
# Development
docker compose up -d

# With Vector log collector
docker compose --profile vector up -d
```

### 2. Systemd (Bare metal / VM)

```bash
# Install dependencies
apt-get install -y clickhouse-server

# Install Perl modules
cpanm Mojolicious Moo JSON::XS YAML::XS HTTP::Tiny

# Copy service files
cp deploy/systemd/purl.service /etc/systemd/system/
cp deploy/systemd/vector.service /etc/systemd/system/

# Configure
cp .env.example /etc/purl/purl.env
vim /etc/purl/purl.env

# Start services
systemctl daemon-reload
systemctl enable --now clickhouse-server purl vector
```

### 3. Kubernetes

```bash
# Generate secure credentials
CLICKHOUSE_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
API_KEY=$(openssl rand -base64 32 | tr -d '/+=')

# Update secrets
sed -i "s/PURL_CLICKHOUSE_PASSWORD: \"CHANGE_ME\"/PURL_CLICKHOUSE_PASSWORD: \"$CLICKHOUSE_PASSWORD\"/" deploy/kubernetes/secret.yaml
sed -i "s/PURL_API_KEYS: \"CHANGE_ME\"/PURL_API_KEYS: \"$API_KEY\"/" deploy/kubernetes/secret.yaml

# Update Ingress host (change purl.example.com to your domain)
vim deploy/kubernetes/purl.yaml

# Deploy all resources
kubectl apply -k deploy/kubernetes/
```

**Resources created:**

| Resource | Type | Description |
|----------|------|-------------|
| `purl` | Deployment | API server (2 replicas) |
| `clickhouse` | StatefulSet | Log storage with PVC |
| `vector` | DaemonSet | Log collector on every node |
| `purl` | Service + Ingress | External access |
| `clickhouse` | Headless Service | Internal DB access |

**Verify deployment:**

```bash
# Check all pods are running
kubectl get pods -n purl

# Check Vector is collecting logs
kubectl logs -n purl -l app.kubernetes.io/name=vector --tail=50

# Check Purl API health
kubectl exec -n purl deploy/purl -- curl -s localhost:3000/api/health
```

## Multi-Server Setup

### Step 1: Configure Central Purl Server

Edit `.env`:

```bash
# Enable authentication (REQUIRED for multi-server)
PURL_AUTH_ENABLED=1
PURL_API_KEYS=your-secret-api-key-here

# ClickHouse credentials
PURL_CLICKHOUSE_USER=purl
PURL_CLICKHOUSE_PASSWORD=purl_password
```

Expose port 3000

```bash
ufw allow 3000/tcp
```

### Step 2: Install Vector on Remote Servers

```bash
# Install Vector
curl -sSL https://sh.vector.dev | bash

# Copy remote config
cp deploy/vector/vector-remote.toml /etc/vector/vector.toml

# Configure environment
cat >> /etc/default/vector << EOF
PURL_URL=http://your-purl-server:3000
PURL_API_KEY=your-secret-api-key-here
EOF

# Start Vector
systemctl enable --now vector

# Check logs
journalctl -u vector -f
```

## Features

### Search & Filter

- KQL query syntax: `level:ERROR AND service:api*`
- Time range picker (5m to 30d)
- Field-based filtering (level, service, host)
- Full-text search in messages

### Live Tail

- Real-time log streaming via WebSocket
- Server-side filtering (reduces bandwidth)
- Auto-scroll with latest logs

### Saved Searches

- Save frequently used queries
- Quick access from sidebar
- Include time range with search

### Alerts

- Define threshold-based alerts
- Notifications via Telegram, Slack, or custom webhook
- Configure time windows and conditions

### Security

- API Key authentication (Sec-Fetch-Site header based for web UI)
- Rate limiting (1000 req/min per IP)
- SQL injection protection (parameterized queries)
- Input validation and sanitization
- XSS protection (HTML escaping in search highlights)
- Graceful shutdown with buffer flush

## Configuration

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `PURL_PORT` | `3000` | Server port |
| `PURL_CLICKHOUSE_HOST` | `clickhouse` | ClickHouse host |
| `PURL_CLICKHOUSE_PORT` | `8123` | ClickHouse HTTP port |
| `PURL_CLICKHOUSE_USER` | `purl` | ClickHouse user |
| `PURL_CLICKHOUSE_PASSWORD` | `purl_password` | ClickHouse password |
| `PURL_RETENTION_DAYS` | `30` | Log retention (days) |
| `PURL_AUTH_ENABLED` | `1` | Enable authentication |
| `PURL_API_KEYS` | (empty) | Comma-separated API keys |
| `PURL_TELEGRAM_BOT_TOKEN` | (empty) | Telegram bot token |
| `PURL_TELEGRAM_CHAT_ID` | (empty) | Telegram chat ID |
| `PURL_SLACK_WEBHOOK_URL` | (empty) | Slack webhook URL |

## API Reference

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/metrics` | GET | Prometheus metrics |
| `/api/logs` | GET | Search logs |
| `/api/logs` | POST | Ingest logs |
| `/api/logs/stream` | WS | Live tail WebSocket |
| `/api/stats` | GET | Database stats |
| `/api/stats/fields/:field` | GET | Field statistics |
| `/api/stats/histogram` | GET | Time histogram |
| `/api/saved-searches` | GET/POST/DELETE | Saved searches CRUD |
| `/api/alerts` | GET/POST/PUT/DELETE | Alerts CRUD |
| `/api/alerts/check` | POST | Check and trigger alerts |

**Query Parameters for GET /api/logs:**

| Param | Example | Description |
|-------|---------|-------------|
| `q` | `level:ERROR` | KQL query |
| `range` | `1h`, `24h`, `7d` | Time range |
| `level` | `ERROR` | Filter by level |
| `service` | `api` | Filter by service |
| `limit` | `100` | Max results |

## Search Syntax (KQL)

```text
# Simple search
error
connection refused

# Field search
level:ERROR
service:api-gateway
host:prod-*

# Combine with AND/OR
level:ERROR AND service:api
level:WARN OR level:ERROR

# Wildcards
service:api*
message:*timeout*
```

## Development

```bash
# Install deps
cpanm --installdeps .
cd web && npm install

# Run linters
make lint

# Build frontend
make web-build

# Run locally
make up
```

## Tech Stack

- **Backend**: Perl 5.38, Mojolicious
- **Storage**: ClickHouse (MergeTree, ZSTD, LowCardinality)
- **Frontend**: Svelte 5, Vite
- **Log Collection**: Vector
- **Deploy**: Docker, Kubernetes, Systemd
