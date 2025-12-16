# Purl Auto-Tracing with Grafana Beyla

**Automatic distributed tracing for ANY application without code changes.**

Beyla uses eBPF to automatically instrument applications at the kernel level, capturing HTTP, gRPC, SQL, Redis, and Kafka traces.

## Requirements

| Requirement | Value |
|-------------|-------|
| Linux Kernel | 5.8+ with BTF enabled |
| Docker | With `--privileged` support |
| Architecture | x86_64 or ARM64 |

### Check System Compatibility

```bash
# Check kernel version (need 5.8+)
uname -r

# Check BTF support
ls /sys/kernel/btf/vmlinux && echo "BTF: OK"
```

## Quick Start

### Option 1: Unified Installer (Recommended)

```bash
# Install everything: Purl + Vector + Beyla
curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | sudo bash
```

### Option 2: Add Beyla to Existing Purl

```bash
cd /opt/purl
docker compose -f deploy/beyla/docker-compose.beyla.yml up -d
```

### Option 3: Install Agent on Remote Server

```bash
curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/purl/main/install.sh | sudo bash -s -- --agent
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PURL_OTLP_ENDPOINT` | `http://localhost:3000` | Purl server URL |
| `BEYLA_DISCOVERY_SERVICES` | `.*` | Service discovery regex |
| `BEYLA_LOG_LEVEL` | `INFO` | Log verbosity (DEBUG, INFO, WARN, ERROR) |
| `ENVIRONMENT` | `production` | Deployment environment |
| `HOSTNAME` | System hostname | Host identifier |

### Auto-Discovery

Beyla automatically discovers and traces all applications. By default:

```yaml
BEYLA_DISCOVERY_SERVICES: ".*"  # Match all services
```

To trace specific services:

```yaml
BEYLA_DISCOVERY_SERVICES: "(api|web|worker)"  # Only these services
```

### Monitor Specific Ports

```yaml
environment:
  BEYLA_OPEN_PORT: "8080,3000,5000"  # Only these ports
```

## What Gets Traced

| Protocol | Examples |
|----------|----------|
| HTTP/1.x, HTTP/2 | REST APIs, Web servers |
| gRPC | Microservices |
| SQL | PostgreSQL, MySQL, SQLite queries |
| Redis | Cache operations |
| Kafka | Message queue operations |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              Your Applications (Any Language)                │
│     Go • Python • Node.js • Java • Ruby • Rust • C++        │
│              (No code changes required!)                     │
└─────────────────────────────────────────────────────────────┘
                            │
                   eBPF Kernel Hooks
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Grafana Beyla 2.8.2                       │
│                                                              │
│  • Auto-discovers all HTTP services                          │
│  • Captures request/response metadata                        │
│  • Generates OpenTelemetry spans                            │
└─────────────────────────────────────────────────────────────┘
                            │
                      OTLP/HTTP
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                          Purl                                │
│                                                              │
│  POST /v1/traces ──► ClickHouse spans table                 │
│                                                              │
│  UI: Waterfall view, Service map, Attributes                │
└─────────────────────────────────────────────────────────────┘
```

## Viewing Traces

1. Open Purl at `http://your-server:3000`
2. Go to **Traces** page
3. Click on any trace to see:
   - Waterfall visualization
   - Span hierarchy (parent-child)
   - Duration breakdown
   - Span attributes (HTTP method, path, status code)
   - Events and errors

## Troubleshooting

### "Operation not permitted"

Beyla requires privileged mode:

```bash
docker run --privileged --pid=host ...
```

### No traces appearing

1. Check Beyla logs:
   ```bash
   docker logs purl-beyla
   ```

2. Verify OTLP endpoint:
   ```bash
   curl -X POST http://localhost:3000/v1/traces \
     -H "Content-Type: application/json" \
     -d '{"resourceSpans":[]}'
   # Should return: {}
   ```

3. Check if your app is detected:
   ```bash
   docker logs purl-beyla | grep -i "discovered"
   ```

### BTF not available

Install BTF support:

```bash
# Ubuntu/Debian
apt-get install linux-tools-$(uname -r)

# Or use BTF archive
export BEYLA_BTF_PATH=/path/to/btf/file
```

## Performance

Beyla has minimal overhead:
- ~1-2% CPU overhead
- ~50MB memory usage
- No application code changes
- Works with compiled binaries

## Supported Languages

Works with ANY language that makes HTTP/gRPC calls:

✅ Go
✅ Python (Django, Flask, FastAPI)
✅ Node.js (Express, Fastify, NestJS)
✅ Java (Spring Boot, Quarkus)
✅ Ruby (Rails, Sinatra)
✅ Rust (Actix, Axum)
✅ C/C++
✅ .NET Core
✅ PHP
✅ Elixir

## Links

- [Grafana Beyla Documentation](https://grafana.com/docs/beyla/latest/)
- [OpenTelemetry OTLP Specification](https://opentelemetry.io/docs/specs/otlp/)
- [eBPF.io](https://ebpf.io/)
