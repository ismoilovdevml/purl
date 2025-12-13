# Purl

Lightweight log aggregation system with ClickHouse. Collect, search, analyze, and alert.

```text
  ____            _
 |  _ \ _   _ _ _| |
 | |_) | | | | '_| |
 |  __/| |_| | | | |
 |_|    \__,_|_| |_|
```

## Why Purl?

| Problem | Solution |
|---------|----------|
| Logs scattered across servers | Single dashboard for all logs |
| Kibana/ELK too heavy | Runs on 512MB RAM |
| Complex setup | One-line install |
| No real-time view | WebSocket live tail |
| Missing alerts | Telegram/Slack/Webhook notifications |

## Quick Start

### Install Purl Server

```bash
curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | sudo bash -s -- -i
```

### Install Vector Agent (Remote Servers)

```bash
curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | sudo bash -s -- --agent -i
```

That's it. Open `http://your-server:3000` and start searching logs.

## Architecture

```text
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│    Server 1     │   │    Server 2     │   │    Server N     │
│  Vector Agent   │   │  Vector Agent   │   │  Vector Agent   │
└────────┬────────┘   └────────┬────────┘   └────────┬────────┘
         │                     │                     │
         └─────────── HTTP + API Key ────────────────┘
                               │
                               ▼
              ┌────────────────────────────────┐
              │         Purl Server            │
              │                                │
              │  ┌──────────┐  ┌────────────┐  │
              │  │ Purl API │──│ ClickHouse │  │
              │  │  :3000   │  │   :8123    │  │
              │  └──────────┘  └────────────┘  │
              │                                │
              │  • API Key Authentication      │
              │  • Rate Limiting (1000/min)    │
              │  • WebSocket Live Tail         │
              │  • 30-day TTL Retention        │
              └────────────────────────────────┘
```

## Features

### Search (KQL Syntax)

```text
level:ERROR                          # Field search
level:ERROR AND service:api          # Combine conditions
service:api*                         # Wildcards
message:*timeout*                    # Text search
```

### Live Tail

Real-time log streaming via WebSocket with server-side filtering.

### Alerts

Threshold-based alerts with Telegram, Slack, or webhook notifications.

### Saved Searches

Save and reuse frequent queries with one click.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PURL_PORT` | `3000` | Server port |
| `PURL_CLICKHOUSE_PASSWORD` | - | ClickHouse password |
| `PURL_API_KEYS` | - | Comma-separated API keys |
| `PURL_RETENTION_DAYS` | `30` | Log retention days |
| `PURL_TELEGRAM_BOT_TOKEN` | - | Telegram bot token |
| `PURL_TELEGRAM_CHAT_ID` | - | Telegram chat ID |
| `PURL_SLACK_WEBHOOK_URL` | - | Slack webhook URL |

## API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/logs` | GET | Search logs |
| `/api/logs` | POST | Ingest logs |
| `/api/logs/stream` | WS | Live tail |
| `/api/stats/histogram` | GET | Time histogram |
| `/api/alerts` | CRUD | Manage alerts |
| `/api/saved-searches` | CRUD | Manage saved searches |

**Search Parameters:**

```
GET /api/logs?q=level:ERROR&range=1h&limit=100
```

## Kubernetes

```bash
kubectl apply -k deploy/kubernetes/
```

## Development

```bash
make lint      # Run linters
make up        # Start services
make web-dev   # Frontend dev server
```

## Tech Stack

- **Backend**: Perl, Mojolicious
- **Storage**: ClickHouse
- **Frontend**: Svelte 5
- **Log Collector**: Vector
- **Deploy**: Docker, Kubernetes
