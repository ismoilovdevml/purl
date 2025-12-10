# Purl

Universal log parser with OpenSearch-like dashboard. Built with Perl + ClickHouse + Svelte.

```
  ____            _
 |  _ \ _   _ _ _| |
 | |_) | | | | '_| |
 |  __/| |_| | | | |
 |_|    \__,_|_| |_|
```

## Quick Start

```bash
docker-compose up -d
open http://localhost:3000
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         PURL SYSTEM                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐ │
│  │   Sources    │     │   Collector  │     │    ClickHouse    │ │
│  │              │     │              │     │                  │ │
│  │ - Files      │────▶│ - Detect     │────▶│ - MergeTree      │ │
│  │ - Docker     │     │ - Parse      │     │ - Partitions     │ │
│  │ - Stdin      │     │ - Normalize  │     │ - TTL Retention  │ │
│  │ - API POST   │     │ - Buffer     │     │                  │ │
│  └──────────────┘     └──────────────┘     └────────┬─────────┘ │
│                                                      │          │
│                                                      ▼          │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐ │
│  │  Dashboard   │◀────│  API Server  │◀────│   Query Engine   │ │
│  │   (Svelte)   │     │ (Mojolicious)│     │                  │ │
│  │              │     │              │     │ - KQL Parser     │ │
│  │ - Search     │     │ - REST API   │     │ - Field Stats    │ │
│  │ - Histogram  │     │ - WebSocket  │     │ - Histogram      │ │
│  │ - Fields     │     │ - Ingest     │     │                  │ │
│  └──────────────┘     └──────────────┘     └──────────────────┘ │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Features

- **Auto-detect** 14 log formats (nginx, json, syslog, docker, etc.)
- **KQL search** - `level:ERROR AND service:api*`
- **Real-time** histogram and field statistics
- **ClickHouse** storage with automatic TTL retention
- **Dark theme** dashboard

## Log Formats Supported

| Format | Example |
|--------|---------|
| JSON | `{"level":"error","msg":"failed"}` |
| Nginx Combined | `127.0.0.1 - - [10/Dec/2025:12:00:00] "GET / HTTP/1.1" 200` |
| Syslog | `Dec 10 12:00:00 host app[123]: message` |
| Docker | `2025-12-10T12:00:00.000Z stdout message` |
| Apache | `127.0.0.1 - - [10/Dec/2025:12:00:00 +0000] "GET /"` |
| Log4j | `2025-12-10 12:00:00,000 ERROR [main] - message` |

## API

```bash
# Health
curl http://localhost:3000/api/health

# Search logs
curl "http://localhost:3000/api/logs?q=level:ERROR&limit=100"

# Ingest log
curl -X POST http://localhost:3000/api/logs \
  -H "Content-Type: application/json" \
  -d '{"level":"ERROR","service":"api","message":"Connection failed"}'

# Field stats
curl "http://localhost:3000/api/stats/fields/level"

# Histogram
curl "http://localhost:3000/api/stats/histogram?range=1h"
```

## Import Docker Logs

```bash
./scripts/send-docker-logs.sh <container_name>
```

## Project Structure

```
purl/
├── bin/purl              # CLI entrypoint
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
├── docker-compose.yml
└── Dockerfile
```

## Unified Log Schema

```json
{
  "timestamp": "2025-12-10T12:00:00Z",
  "level": "ERROR",
  "service": "api-gateway",
  "host": "prod-01",
  "message": "Connection refused",
  "raw": "original log line",
  "meta": {}
}
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PURL_PORT` | 3000 | Server port |
| `PURL_CLICKHOUSE_HOST` | clickhouse | ClickHouse host |
| `PURL_CLICKHOUSE_PORT` | 8123 | ClickHouse HTTP port |
| `PURL_RETENTION_DAYS` | 30 | Log retention days |

## Tech Stack

- **Backend**: Perl 5.38, Mojolicious, Moo
- **Storage**: ClickHouse (MergeTree, TTL)
- **Frontend**: Svelte, Vite
- **Deploy**: Docker, Docker Compose

## License

MIT
