# Purl Deployment Guide

## Overview

Purl supports multiple deployment options:

| Environment | Method | Auto-collect |
|-------------|--------|--------------|
| Docker | docker-compose + Vector | All containers |
| Kubernetes | Helm chart + DaemonSet | All pods |
| Systemd | systemd units + Vector | journald + files |

## Quick Start

### Docker (Recommended for single server)

```bash
# Basic (manual log sending only)
docker-compose up -d
open http://localhost:3000

# With Vector (auto-collect all container logs)
docker-compose --profile vector up -d
```

### Kubernetes

```bash
# Using Helm
helm install purl ./deploy/helm/purl -n purl --create-namespace

# Using kubectl
kubectl apply -f deploy/kubernetes/
```

### Systemd (Bare metal)

```bash
sudo ./deploy/systemd/install.sh
```

---

## Docker Deployment

### Architecture

```text
┌──────────────────────────────────────────────────────────────────┐
│                      Docker Host                                 │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                  │
│  │  nginx     │  │  myapp     │  │  postgres  │   Your Apps      │
│  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘                  │
│        │               │               │                         │
│        └───────────────┴───────────────┘                         │
│                        │                                         │
│                        ▼                                         │
│               ┌────────────────┐                                 │
│               │    Vector      │  Collects via Docker socket     │
│               │  (DaemonSet)   │                                 │
│               └────────┬───────┘                                 │
│                        │                                         │
│                        ▼                                         │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                       Purl                                 │  │
│  │  ┌───────────┐   ┌──────────────┐   ┌────────────────────┐ │  │
│  │  │ Dashboard │←──│  API Server  │←──│    ClickHouse      │ │  │
│  │  │  :3000    │   │              │   │                    │ │  │
│  │  └───────────┘   └──────────────┘   └────────────────────┘ │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Basic Setup

```bash
cd purl
docker-compose up -d
```

This starts:
- Purl API + Dashboard on port 3000
- ClickHouse on port 8123

Logs must be sent manually via API.

### With Auto-Collection (Vector)

```bash
docker-compose --profile vector up -d
```

This additionally starts Vector which:
- Connects to Docker socket
- Collects logs from ALL containers
- Parses JSON logs automatically
- Sends to Purl API

### Configuration

Edit `deploy/docker/vector.yaml` to:

```yaml
sources:
  docker_logs:
    type: docker_logs
    # Exclude specific containers
    exclude_containers:
      - "vector"
      - "purl-clickhouse"
```

### Add Custom Log Sources

```yaml
# Add to deploy/docker/vector.yaml

sources:
  # Application logs from mounted volume
  app_logs:
    type: file
    include:
      - /var/log/myapp/*.log

  # Remote syslog
  syslog:
    type: syslog
    address: "0.0.0.0:514"
```

---

## Kubernetes Deployment

### Architecture

```text
┌──────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                            │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Node 1                    Node 2                    Node 3      │
│  ┌──────────────────┐     ┌──────────────────┐     ┌───────────┐ │
│  │ ┌─────┐ ┌─────┐  │     │ ┌─────┐ ┌─────┐  │     │ ┌─────┐   │ │
│  │ │Pod A│ │Pod B│  │     │ │Pod C│ │Pod D│  │     │ │Pod E│   │ │
│  │ └──┬──┘ └──┬──┘  │     │ └──┬──┘ └──┬──┘  │     │ └──┬──┘   │ │
│  │    └───┬───┘     │     │    └───┬───┘     │     │    │      │ │
│  │        ▼         │     │        ▼         │     │    ▼      │ │
│  │   ┌─────────┐    │     │   ┌─────────┐    │     │ ┌──────┐  │ │
│  │   │ Vector  │    │     │   │ Vector  │    │     │ │Vector│  │ │
│  │   │DaemonSet│    │     │   │DaemonSet│    │     │ │      │  │ │
│  │   └────┬────┘    │     │   └────┬────┘    │     │ └──┬───┘  │ │
│  └────────┼─────────┘     └────────┼─────────┘     └────┼──────┘ │
│           └────────────────────────┴────────────────────┘        │
│                                    │                             │
│                                    ▼                             │
│           ┌─────────────────────────────────────┐                │
│           │              Purl                   │                │
│           │  ┌─────────┐      ┌───────────────┐ │                │
│           │  │ API x2  │      │  ClickHouse   │ │                │
│           │  │ (Pods)  │      │ (StatefulSet) │ │                │
│           │  └─────────┘      └───────────────┘ │                │
│           └─────────────────────────────────────┘                │
│                              │                                   │
│                              ▼                                   │
│                         ┌─────────┐                              │
│                         │ Ingress │                              │
│                         │logs.com │                              │
│                         └─────────┘                              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Using Helm (Recommended)

```bash
# Install
helm install purl ./deploy/helm/purl \
  --namespace purl \
  --create-namespace \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=logs.example.com

# Upgrade
helm upgrade purl ./deploy/helm/purl -n purl

# Uninstall
helm uninstall purl -n purl
```

### Helm Values

```yaml
# values.yaml
purl:
  replicaCount: 3
  resources:
    requests:
      memory: "256Mi"
      cpu: "200m"
    limits:
      memory: "1Gi"
      cpu: "1000m"

clickhouse:
  persistence:
    size: 50Gi
    storageClass: "fast-ssd"

vector:
  enabled: true
  excludeNamespaces:
    - kube-system
    - kube-public
    - monitoring

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: logs.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: logs-tls
      hosts:
        - logs.example.com
```

### Using kubectl

```bash
# Create namespace
kubectl apply -f deploy/kubernetes/namespace.yaml

# Deploy ClickHouse
kubectl apply -f deploy/kubernetes/clickhouse.yaml

# Wait for ClickHouse
kubectl wait --for=condition=ready pod -l app=clickhouse -n purl --timeout=120s

# Deploy Purl
kubectl apply -f deploy/kubernetes/purl.yaml

# Deploy Vector DaemonSet
kubectl apply -f deploy/kubernetes/vector-daemonset.yaml

# Check status
kubectl get pods -n purl
```

### What Gets Collected

Vector DaemonSet automatically collects:
- All pod stdout/stderr logs
- Kubernetes metadata (namespace, pod name, labels)
- Container names

Metadata enrichment:
```json
{
  "level": "ERROR",
  "service": "my-app",           // from app.kubernetes.io/name label
  "host": "my-app-abc123",       // pod name
  "message": "Connection failed",
  "meta": {
    "namespace": "production",
    "pod": "my-app-abc123",
    "container": "main",
    "node": "node-1"
  }
}
```

### Exclude Namespaces

Edit Vector ConfigMap:

```yaml
sources:
  kubernetes_logs:
    type: kubernetes_logs
    extra_label_selector: "app!=vector"
```

Or in Helm values:

```yaml
vector:
  excludeNamespaces:
    - kube-system
    - istio-system
```

---

## Systemd Deployment

### Architecture

```text
┌─────────────────────────────────────────────────────────────────┐
│                       Linux Server                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  systemd services                                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ nginx.service│  │ myapp.service│  │ sshd.service │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                 │                 │                   │
│         └─────────────────┴─────────────────┘                   │
│                           │                                     │
│                           ▼                                     │
│                    ┌─────────────┐                              │
│                    │  journald   │                              │
│                    └──────┬──────┘                              │
│                           │                                     │
│  /var/log/               │                                      │
│  ├── nginx/              │                                      │
│  ├── myapp/              │                                      │
│  └── syslog              │                                      │
│         │                │                                      │
│         └────────┬───────┘                                      │
│                  ▼                                              │
│           ┌─────────────┐                                       │
│           │   Vector    │ vector.service                        │
│           │  (systemd)  │                                       │
│           └──────┬──────┘                                       │
│                  │                                              │
│                  ▼                                              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                        Purl                                │ │
│  │  ┌───────────┐  ┌──────────────┐  ┌────────────────────┐   │ │
│  │  │ Dashboard │  │  API Server  │  │    ClickHouse      │   │ │
│  │  │  :3000    │  │ purl.service │  │clickhouse.service  │   │ │
│  │  └───────────┘  └──────────────┘  └────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Quick Install

```bash
# Download and run installer
sudo ./deploy/systemd/install.sh
```

This installs:
- ClickHouse server
- Purl application
- Vector log collector
- systemd service units

### Manual Installation

```bash
# 1. Install ClickHouse
curl https://clickhouse.com/ | sh
sudo ./clickhouse install
sudo systemctl enable --now clickhouse-server

# 2. Install Purl
sudo mkdir -p /opt/purl
sudo git clone https://github.com/your-username/purl.git /opt/purl
cd /opt/purl
sudo cpanm --installdeps .
cd web && sudo npm install && sudo npm run build && cd ..

# Create user
sudo useradd -r -s /bin/false purl
sudo chown -R purl:purl /opt/purl

# Install service
sudo cp deploy/systemd/purl.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now purl

# 3. Install Vector
curl --proto '=https' --tlsv1.2 -sSfL https://sh.vector.dev | sudo bash -s -- -y

# Create user
sudo useradd -r -s /bin/false vector
sudo mkdir -p /var/lib/vector
sudo chown vector:vector /var/lib/vector

# Configure
sudo mkdir -p /etc/vector
sudo cp deploy/systemd/vector.yaml /etc/vector/vector.yaml

# Install service
sudo cp deploy/systemd/vector.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vector
```

### What Gets Collected

Vector collects:
- **journald**: All systemd service logs
- **/var/log/*.log**: System logs
- **/var/log/nginx/**: Nginx access/error logs

### Add Custom Sources

Edit `/etc/vector/vector.yaml`:

```yaml
sources:
  # Your application logs
  myapp_logs:
    type: file
    include:
      - /var/log/myapp/*.log
      - /home/*/logs/*.log

  # Docker containers (if Docker installed)
  docker_logs:
    type: docker_logs

  # Remote syslog from other servers
  remote_syslog:
    type: syslog
    address: "0.0.0.0:514"
```

Then restart:

```bash
sudo systemctl restart vector
```

### View Logs

```bash
# Purl logs
journalctl -u purl -f

# Vector logs
journalctl -u vector -f

# ClickHouse logs
journalctl -u clickhouse-server -f
```

---

## Sending Custom Logs

### From Any Application

```bash
# Bash
curl -X POST http://purl:3000/api/logs \
  -H "Content-Type: application/json" \
  -d '{"level":"ERROR","service":"myapp","message":"Something failed"}'

# Batch
curl -X POST http://purl:3000/api/logs \
  -H "Content-Type: application/json" \
  -d '[{"level":"INFO","service":"myapp","message":"Log 1"},
       {"level":"WARN","service":"myapp","message":"Log 2"}]'
```

### From Docker Container

```bash
# Inside container
curl -X POST http://purl:3000/api/logs \
  -H "Content-Type: application/json" \
  -d "{\"level\":\"INFO\",\"service\":\"$HOSTNAME\",\"message\":\"Hello\"}"
```

### From Kubernetes Pod

```bash
# Inside pod
curl -X POST http://purl.purl.svc.cluster.local:3000/api/logs \
  -H "Content-Type: application/json" \
  -d '{"level":"INFO","service":"my-pod","message":"Hello from K8s"}'
```

---

## Production Checklist

### Security

- [ ] Enable HTTPS (via ingress/nginx)
- [ ] Set up authentication (basic auth or OAuth proxy)
- [ ] Restrict ClickHouse access (internal network only)
- [ ] Use secrets for passwords

### High Availability

- [ ] Run multiple Purl replicas
- [ ] ClickHouse cluster (for large scale)
- [ ] Load balancer in front

### Monitoring

- [ ] Monitor `/api/health` endpoint
- [ ] Alert on high error rate
- [ ] Monitor ClickHouse disk usage

### Retention

- [ ] Configure `PURL_RETENTION_DAYS` (default: 30)
- [ ] Set up ClickHouse TTL for automatic cleanup

---

## Troubleshooting

### Logs not appearing

1. Check Vector is running:
   ```bash
   # Docker
   docker logs purl-vector

   # K8s
   kubectl logs -l app.kubernetes.io/component=vector -n purl

   # Systemd
   journalctl -u vector -f
   ```

2. Check Purl API:
   ```bash
   curl http://localhost:3000/api/health
   curl http://localhost:3000/api/stats
   ```

3. Test manual insert:
   ```bash
   curl -X POST http://localhost:3000/api/logs \
     -H "Content-Type: application/json" \
     -d '{"level":"TEST","service":"debug","message":"Test log"}'
   ```

### ClickHouse connection error

```bash
# Check ClickHouse
curl http://localhost:8123/ping

# Check database
curl "http://localhost:8123/?query=SHOW%20DATABASES"
```

### High memory usage

Reduce Vector batch size in config:

```yaml
sinks:
  purl:
    batch:
      max_events: 50  # Reduce from 100
      timeout_secs: 2
```
