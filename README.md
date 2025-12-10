# Purl

Universal log parser with OpenSearch-like dashboard. Built with Perl + ClickHouse + Svelte.

```text
  ____            _
 |  _ \ _   _ _ _| |
 | |_) | | | | '_| |
 |  __/| |_| | | | |
 |_|    \__,_|_| |_|
```

## Problem

- Logs scattered across multiple servers and services
- Different log formats (nginx, docker, json, syslog, etc.)
- No unified search interface
- Kibana/OpenSearch too heavy for small-medium projects
- Need quick log analysis without complex setup

## Solution

Purl provides:

- **Single dashboard** for all logs from any source
- **Auto-detect** 14 log formats - no configuration needed
- **KQL search** - familiar syntax like `level:ERROR AND service:api*`
- **Lightweight** - runs on 512MB RAM
- **Fast** - ClickHouse handles millions of logs

## Architecture

```text
┌─────────────────────────────────────────────────────────────────┐
│                         PURL SYSTEM                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐ │
│  │   Sources    │     │   Collector  │     │    ClickHouse    │ │
│  │              │     │              │     │                  │ │
│  │ - Files      │────▶│ - Detect     │────▶│ - MergeTree      │ │
│  │ - Docker     │     │ - Parse      │     │ - Partitions     │ │
│  │ - Stdin      │     │ - Normalize  │     │ - TTL Retention  │ │
│  │ - API POST   │     │ - Buffer     │     │                  │ │
│  └──────────────┘     └──────────────┘     └────────┬─────────┘ │
│                                                     │           │
│                                                     ▼           │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐ │
│  │  Dashboard   │◀────│  API Server  │◀────│   Query Engine   │ │
│  │   (Svelte)   │     │ (Mojolicious)│     │                  │ │
│  │              │     │              │     │ - KQL Parser     │ │
│  │ - Search     │     │ - REST API   │     │ - Field Stats    │ │
│  │ - Histogram  │     │ - WebSocket  │     │ - Histogram      │ │
│  │ - Fields     │     │ - Ingest     │     │                  │ │
│  └──────────────┘     └──────────────┘     └──────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start (Local)

```bash
git clone https://github.com/your-username/purl.git
cd purl
docker-compose up -d
open http://localhost:3000
```

## Server Setup

### Option 1: Docker Compose (Recommended)

```bash
# On your server
git clone https://github.com/your-username/purl.git /opt/purl
cd /opt/purl

# Configure (optional)
cp config/default.yaml config/local.yaml
vi config/local.yaml

# Start
docker-compose up -d

# Check status
docker-compose ps
curl http://localhost:3000/api/health
```

### Option 2: Systemd Service

```bash
# Install dependencies
cpanm --installdeps .
cd web && npm install && npm run build && cd ..

# Create systemd service
sudo tee /etc/systemd/system/purl.service << 'EOF'
[Unit]
Description=Purl Log Dashboard
After=network.target

[Service]
Type=simple
User=purl
WorkingDirectory=/opt/purl
ExecStart=/usr/bin/perl bin/purl server -p 3000
Restart=always
Environment=PURL_CLICKHOUSE_HOST=localhost

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable purl
sudo systemctl start purl
```

### Option 3: Behind Nginx

```nginx
server {
    listen 80;
    server_name logs.example.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Sending Logs to Purl

### Method 1: HTTP API (Any Language)

```bash
# Single log
curl -X POST http://your-server:3000/api/logs \
  -H "Content-Type: application/json" \
  -d '{"level":"ERROR","service":"api","host":"prod-01","message":"Connection failed"}'

# Batch (array)
curl -X POST http://your-server:3000/api/logs \
  -H "Content-Type: application/json" \
  -d '[
    {"level":"INFO","service":"auth","message":"User login"},
    {"level":"ERROR","service":"api","message":"Timeout"}
  ]'
```

### Method 2: Docker Container Logs

```bash
# Import existing logs
./scripts/send-docker-logs.sh nginx http://your-server:3000
./scripts/send-docker-logs.sh postgres http://your-server:3000

# Or pipe directly
docker logs -f myapp 2>&1 | curl -X POST http://your-server:3000/api/logs \
  -H "Content-Type: application/json" -d @-
```

### Method 3: File Tail (Server-side)

```bash
# Tail nginx logs
tail -F /var/log/nginx/access.log | perl bin/purl parse -f nginx | \
  curl -X POST http://localhost:3000/api/logs -H "Content-Type: application/json" -d @-

# Or use collector
perl bin/purl collect -s /var/log/nginx/access.log -s /var/log/app/*.log
```

### Method 4: Application Integration

**Python:**

```python
import requests
import logging

class PurlHandler(logging.Handler):
    def __init__(self, url):
        super().__init__()
        self.url = url

    def emit(self, record):
        requests.post(f"{self.url}/api/logs", json={
            "level": record.levelname,
            "service": record.name,
            "message": record.getMessage(),
            "host": "prod-01"
        })

# Usage
logger = logging.getLogger("myapp")
logger.addHandler(PurlHandler("http://your-server:3000"))
logger.error("Something went wrong")
```

**Node.js:**

```javascript
const fetch = require('node-fetch');

async function sendLog(level, message, service = 'myapp') {
  await fetch('http://your-server:3000/api/logs', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ level, message, service, host: process.env.HOSTNAME })
  });
}

// Usage
sendLog('ERROR', 'Database connection failed', 'api-gateway');
```

**Bash/Shell:**

```bash
# Add to your scripts
log_to_purl() {
  curl -s -X POST http://your-server:3000/api/logs \
    -H "Content-Type: application/json" \
    -d "{\"level\":\"$1\",\"service\":\"$2\",\"message\":\"$3\",\"host\":\"$(hostname)\"}"
}

# Usage
log_to_purl "INFO" "backup-script" "Backup completed successfully"
log_to_purl "ERROR" "deploy-script" "Deployment failed: $error_msg"
```

### Method 5: Filebeat/Vector

```yaml
# vector.toml
[sources.nginx_logs]
type = "file"
include = ["/var/log/nginx/*.log"]

[sinks.purl]
type = "http"
inputs = ["nginx_logs"]
uri = "http://your-server:3000/api/logs"
encoding.codec = "json"
```

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
service:auth AND NOT level:DEBUG

# Wildcards
service:api*
message:*timeout*
host:prod-0?

# Phrases
message:"connection refused"
```

## API Reference

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/logs` | GET | Search logs |
| `/api/logs` | POST | Ingest logs |
| `/api/stats` | GET | Database stats |
| `/api/stats/fields/:field` | GET | Field statistics |
| `/api/stats/histogram` | GET | Time histogram |
| `/api/logs/stream` | WS | Live tail (WebSocket) |

**Query Parameters for GET /api/logs:**

| Param | Example | Description |
|-------|---------|-------------|
| `q` | `level:ERROR` | KQL query |
| `range` | `1h`, `24h`, `7d` | Time range |
| `from` | `2025-01-01T00:00:00Z` | Start time |
| `to` | `2025-01-02T00:00:00Z` | End time |
| `level` | `ERROR` | Filter by level |
| `service` | `api` | Filter by service |
| `limit` | `100` | Max results |

## Log Formats Auto-Detected

| Format | Example |
|--------|---------|
| JSON | `{"level":"error","msg":"failed"}` |
| Nginx Combined | `127.0.0.1 - - [10/Dec/2025:12:00:00] "GET /" 200` |
| Nginx Error | `2025/12/10 12:00:00 [error] message` |
| Syslog | `Dec 10 12:00:00 host app[123]: message` |
| Syslog RFC5424 | `<34>1 2025-12-10T12:00:00Z host app - - message` |
| Docker | `2025-12-10T12:00:00.000Z stdout message` |
| Apache Combined | `127.0.0.1 - - [10/Dec/2025:12:00:00 +0000] "GET /"` |
| Apache Error | `[Mon Dec 10 12:00:00 2025] [error] message` |
| Log4j | `2025-12-10 12:00:00,000 ERROR [main] - message` |
| Python | `2025-12-10 12:00:00,000 - myapp - ERROR - message` |
| Ruby | `E, [2025-12-10T12:00:00] ERROR -- : message` |
| Go | `2025/12/10 12:00:00 message` |
| Kubernetes | `2025-12-10T12:00:00.000Z stderr F message` |
| Common Log | `127.0.0.1 - - [10/Dec/2025:12:00:00] "GET /" 200 1234` |

## Configuration

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `PURL_PORT` | `3000` | Server port |
| `PURL_CLICKHOUSE_HOST` | `clickhouse` | ClickHouse host |
| `PURL_CLICKHOUSE_PORT` | `8123` | ClickHouse HTTP port |
| `PURL_CLICKHOUSE_USER` | `default` | ClickHouse user |
| `PURL_CLICKHOUSE_PASSWORD` | (empty) | ClickHouse password |
| `PURL_RETENTION_DAYS` | `30` | Log retention (days) |
| `PURL_BUFFER_SIZE` | `1000` | Batch insert size |

**config/local.yaml:**

```yaml
server:
  port: 3000
  host: 0.0.0.0

storage:
  clickhouse:
    host: clickhouse
    port: 8123
    database: purl
    retention_days: 30

collector:
  buffer_size: 1000
  flush_interval: 5
```

## Project Structure

```text
purl/
├── bin/purl                    # CLI entrypoint
├── lib/Purl/
│   ├── Parser/
│   │   ├── FormatDetector.pm   # Auto-detect log format
│   │   ├── Engine.pm           # Parse all formats
│   │   └── Normalizer.pm       # Unified JSON schema
│   ├── Storage/
│   │   └── ClickHouse.pm       # ClickHouse HTTP API
│   ├── Query/
│   │   └── KQL.pm              # KQL query parser
│   └── API/
│       └── Server.pm           # Mojolicious REST API
├── web/src/                    # Svelte dashboard
├── scripts/
│   └── send-docker-logs.sh     # Docker log importer
├── config/
│   └── default.yaml            # Default config
├── docker-compose.yml
├── Dockerfile
└── Makefile
```

## CLI Commands

```bash
# Start web server
perl bin/purl server -p 3000

# Collect logs from files
perl bin/purl collect -s /var/log/*.log

# Parse from stdin
cat access.log | perl bin/purl parse -f nginx

# Query logs
perl bin/purl query 'level:ERROR' -r 24h -l 100

# Show stats
perl bin/purl stats

# Cleanup old logs
perl bin/purl cleanup -d 30
```

## Development

```bash
# Install deps
cpanm --installdeps .
cd web && npm install

# Run linters
make lint

# Run tests
make test

# Dev mode (hot reload)
cd web && npm run dev &
perl bin/purl server -p 3000
```

## Tech Stack

- **Backend**: Perl 5.38, Mojolicious, Moo
- **Storage**: ClickHouse (MergeTree, TTL)
- **Frontend**: Svelte, Vite, Chart.js
- **Deploy**: Docker, Docker Compose

## License

MIT
