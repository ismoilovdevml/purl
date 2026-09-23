# Purl

Lightweight log aggregation system with ClickHouse. Collect, search, analyze, and alert.

Purl is free and open source under the [MIT license](LICENSE). Every feature is
available to everyone — there are no paid tiers and no license key.

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
| `PURL_SESSION_MAX_AGE` | `604800` | Absolute session lifetime in seconds |
| `PURL_AI_RATE_LIMIT` | `20` | AI requests per user per minute (`0` disables; exact across workers only with `PURL_REDIS_URL`) |
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
path that receives the security defaults — a ClickHouse password that is never
empty, config persistence, PSS-restricted security contexts, NetworkPolicy
allow-list and the render-time guards that refuse a misconfiguration instead of
starting up quietly wrong.

### Install

```bash
helm repo add purl https://charts.purlogs.com
helm repo update
helm install purl purl/purl -n purl --create-namespace
```

That is the whole command — no flags needed. The chart mints the ClickHouse
password, session secret and ingest API key into the release Secret on first
install, and `helm upgrade` reads them back out, so they stay stable.

It will only do that when it can actually see the cluster. Under `helm
template`, `helm lint` or Argo CD the lookup is blind, every render would mint
a *different* value, and the chart **refuses to render** rather than hand you a
credential that rotates on every sync (issue #22). For GitOps, supply the
credentials yourself — see below.

To pin your own values instead:

```bash
helm install purl purl/purl -n purl --create-namespace \
  --set purl.apiKeys=<your-ingest-key> \
  --set clickhouse.password=<your-password> \
  --set purl.sessionSecret=<your-session-secret>
```

### GitOps (Argo CD, Flux, `helm template | kubectl apply`)

Do **not** set `purl.autoGenerateSecrets` here. Generation depends on `lookup`,
which can only read the cluster during a real `helm install`/`upgrade`. A
clusterless render always sees an empty lookup, so every sync would mint a new
ClickHouse password, session secret and API key — and because the workloads
carry `checksum/secret` annotations, roll Purl and ClickHouse each time. The
result is a permanently OutOfSync app that restart-loops while database auth
fails, every dashboard session drops and every agent key stops working.

With the flag off the chart refuses to render rather than do that silently.
Supply the credentials instead — either pin the three values above, or point at
a Secret you manage out-of-band:

```bash
helm template purl purl/purl --set purl.existingSecret=purl-secrets
```

See `purl.existingSecret` in [`chart/values.yaml`](chart/values.yaml) for the
required keys — note it must carry `PURL_CLICKHOUSE_PASSWORD` when the built-in
ClickHouse is enabled. It also keeps every credential out of
`helm get values` and the release history.

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
`settings.json` survive an uninstall. Delete it explicitly when you mean to.

### Migrating off the old raw manifests

`deploy/kubernetes/` has been removed (issue #41). It predated the chart,
duplicated everything the chart templates and received none of its hardening —
no `securityContext` on any workload, no config persistence (dashboard users
lived in an `emptyDir`), no NetworkPolicy allow-list, no
backups, and a `secret.yaml` shipping `CHANGE_ME` placeholders. The chart is
the only supported Kubernetes path.

If you still have an install from those manifests, there is no in-place
upgrade. ClickHouse data lives on the `clickhouse-data` PVC and can be reused:

```bash
# 1. Note the existing PVC
kubectl -n purl get pvc

# 2. Install the chart into a NEW namespace, either pointing at your existing
#    ClickHouse (--set clickhouse.enabled=false --set clickhouse.host=...)
#    or restoring a backup into a fresh install.

# 3. Remove the old resources — they all carry the kustomize labels
kubectl -n purl delete all,configmap,secret \
  -l app.kubernetes.io/managed-by=kubectl,app.kubernetes.io/part-of=purl
```

The kube-apiserver audit-log integration that used to live alongside those
manifests is unrelated to deployment and now lives in
[`deploy/k8s-audit/`](deploy/k8s-audit/).

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
make up          # Start Purl + ClickHouse with Docker Compose
make web-dev     # Frontend dev server with hot reload
make preflight   # Lint + tests + frontend build — run before opening a PR
```

## Contributing

Bug reports, fixes and features are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for the development setup, branch model and commit style. Report security
issues privately as described in [SECURITY.md](SECURITY.md).

## Tech Stack

- **Backend**: Perl, Mojolicious
- **Storage**: ClickHouse
- **Frontend**: Svelte 5
- **Log Collector**: Vector
- **Deploy**: Docker, Kubernetes

## License

[MIT](LICENSE)
