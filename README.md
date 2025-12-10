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
- **Alerts** - get notified when log patterns match
- **Lightweight** - runs on 512MB RAM
- **Fast** - ClickHouse handles millions of logs

## Architecture

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
│  │ - Saved      │     │ - Metrics    │     │                  │ │
│  └──────────────┘     └──────────────┘     └──────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
git clone https://github.com/your-username/purl.git
cd purl

# Start with auto log collection
docker-compose --profile vector up -d

# Open dashboard
open http://localhost:3000
```

Vector automatically collects logs from **all Docker containers**.

## Features

### Search & Filter
- KQL query syntax: `level:ERROR AND service:api*`
- Time range picker (5m to 30d)
- Field-based filtering (level, service, host)
- Full-text search in messages

### Live Tail
- Real-time log streaming via WebSocket
- Auto-scroll with latest logs
- Toggle on/off without losing position

### Saved Searches
- Save frequently used queries
- Quick access from sidebar
- Include time range with search

### Alerts
- Define threshold-based alerts
- Notifications via webhook, Slack, or browser
- Configure time windows and conditions

### Enterprise Features
- Prometheus metrics (`/api/metrics`)
- In-memory caching with TTL
- Rate limiting (1000 req/min per IP)
- Basic Auth and API Key authentication

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
| `/api/alerts/check` | POST | Check alert conditions |

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

## Sending Logs

### HTTP API

```bash
# Single log
curl -X POST http://localhost:3000/api/logs \
  -H "Content-Type: application/json" \
  -d '{"level":"ERROR","service":"api","host":"prod-01","message":"Connection failed"}'

# Batch
curl -X POST http://localhost:3000/api/logs \
  -H "Content-Type: application/json" \
  -d '[
    {"level":"INFO","service":"auth","message":"User login"},
    {"level":"ERROR","service":"api","message":"Timeout"}
  ]'
```

### Application Integration

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

logger = logging.getLogger("myapp")
logger.addHandler(PurlHandler("http://localhost:3000"))
```

**Node.js:**

```javascript
async function sendLog(level, message, service = 'myapp') {
  await fetch('http://localhost:3000/api/logs', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ level, message, service, host: process.env.HOSTNAME })
  });
}
```

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
| `PURL_AUTH_ENABLED` | `0` | Enable authentication |
| `PURL_AUTH_USER` | `admin` | Basic auth username |
| `PURL_AUTH_PASSWORD` | (empty) | Basic auth password |
| `PURL_API_KEY` | (empty) | API key for auth |

## Project Structure

```text
purl/
├── lib/Purl/
│   ├── API/
│   │   └── Server.pm       # Mojolicious REST API + WebSocket
│   └── Storage/
│       └── ClickHouse.pm   # ClickHouse HTTP client
├── web/src/                # Svelte dashboard
│   ├── components/
│   │   ├── SearchBar.svelte
│   │   ├── TimeRangePicker.svelte
│   │   ├── FieldsSidebar.svelte
│   │   ├── LogTable.svelte
│   │   ├── Histogram.svelte
│   │   ├── SavedSearches.svelte
│   │   └── AlertsPanel.svelte
│   ├── stores/logs.js
│   └── App.svelte
├── config/
│   └── vector.yaml         # Vector log collector config
├── docker-compose.yml
├── Dockerfile
└── Makefile
```

## Development

```bash
# Install deps
cpanm --installdeps .
cd web && npm install

# Run linters
make lint

# Build frontend
cd web && npm run build

# Dev mode (hot reload)
cd web && npm run dev &
docker-compose up purl clickhouse
```

## Tech Stack

- **Backend**: Perl 5.38, Mojolicious
- **Storage**: ClickHouse (MergeTree, ZSTD, LowCardinality)
- **Frontend**: Svelte, Vite
- **Log Collection**: Vector
- **Deploy**: Docker, Docker Compose

## License

MIT
