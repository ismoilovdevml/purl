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
curl -fsSL https://purlogs.com/install.sh | sudo bash -s -- -i
```

### Install Vector Agent (Remote Servers)

```bash
curl -fsSL https://purlogs.com/install.sh | sudo bash -s -- --agent -i
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

The Helm chart is the supported way to run Purl on Kubernetes. It is the only
path that receives the security defaults — generated ClickHouse password,
config persistence, PSS-restricted security contexts, NetworkPolicy allow-list
and the render-time guards that refuse a misconfiguration instead of starting
up quietly wrong.

### Install

```bash
helm repo add purl https://charts.purlogs.com
helm repo update
helm install purl purl/purl -n purl --create-namespace
```

Everything not supplied is generated into the release Secret and kept stable
across upgrades. To pin your own values:

```bash
helm install purl purl/purl -n purl --create-namespace \
  --set purl.apiKeys=<your-ingest-key> \
  --set clickhouse.password=<your-password>
```

For an operator-managed Secret instead (nothing sensitive in
`helm get values` or the release history), see `purl.existingSecret` in
[`chart/values.yaml`](chart/values.yaml) — note it must carry
`PURL_CLICKHOUSE_PASSWORD` when the built-in ClickHouse is enabled.

### Access the dashboard

```bash
kubectl port-forward -n purl svc/purl 3000:3000
# http://localhost:3000 — the initial admin password is written to
# /app/config/initial_admin_password.txt inside the pod and logged once at startup
```

### Upgrade and uninstall

```bash
helm upgrade purl purl/purl -n purl
helm uninstall purl -n purl
```

The config PVC carries `helm.sh/resource-policy: keep`, so dashboard users and
the license key survive an uninstall. Delete it explicitly when you mean to.

### Raw manifests (unmaintained)

`deploy/kubernetes/` predates the chart and no longer receives security or
correctness fixes — its `install.sh` now refuses to run without
`PURL_ACCEPT_UNMAINTAINED=1`. See
[`deploy/kubernetes/README.md`](deploy/kubernetes/README.md) for the gap list
and migration steps. Use the chart.

### Architecture (Kubernetes)

```text
┌────────────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                            │
├───────────────┬───────────────┬───────────────┬────────────────────┤
│    Node 1     │    Node 2     │    Node 3     │      Node N        │
│  ┌─────────┐  │  ┌─────────┐  │  ┌─────────┐  │    ┌─────────┐     │
│  │ Vector  │  │  │ Vector  │  │  │ Vector  │  │    │ Vector  │     │
│  │DaemonSet│  │  │DaemonSet│  │  │DaemonSet│  │    │DaemonSet│     │
│  └────┬────┘  │  └────┬────┘  │  └────┬────┘  │    └────┬────┘     │
│       │       │       │       │       │       │         │          │
│  /var/log/    │  /var/log/    │  /var/log/    │    /var/log/       │
│    pods/      │    pods/      │    pods/      │      pods/         │
└──────┼────────┴──────┼────────┴──────┼────────┴─────────┼──────────┘
       └───────────────┴───────────────┴──────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │   purl Service    │
                    │   (ClusterIP)     │
                    └─────────┬─────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
       ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
       │    Purl     │ │  ClickHouse │ │   Vector    │
       │ Deployment  │ │ StatefulSet │ │  DaemonSet  │
       │   :3000     │ │   :8123     │ │   :8686     │
       └─────────────┘ └─────────────┘ └─────────────┘
```

### Components

| Component | Type | Description |
|-----------|------|-------------|
| `purl` | Deployment | API server and dashboard |
| `clickhouse` | StatefulSet | Log storage with PVC |
| `vector` | DaemonSet | Log collector on each node |

### Kubernetes Metadata

Purl automatically captures K8s metadata:

| Field | Description |
|-------|-------------|
| `namespace` | Pod namespace |
| `pod` | Pod name |
| `container` | Container name |
| `node` | Node name |
| `cluster` | Cluster name (configurable) |

Search examples:
```text
meta.namespace:production          # Filter by namespace
meta.pod:api-*                     # Wildcard pod name
meta.node:worker-1                 # Specific node
```

### Production Setup

For production, add Ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: purl
  namespace: purl
spec:
  rules:
    - host: logs.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: purl
                port:
                  number: 80
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
