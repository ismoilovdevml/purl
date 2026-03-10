# External Integrations

**Analysis Date:** 2026-03-10

## APIs & External Services

**Log Ingest:**
- Vector - Log collector agent (optional, via Docker profile)
  - Integration: HTTP POST `/api/logs` endpoint
  - Format: Purl native JSON or OTLP/JSON
  - Auth: API key (one-time or per-request header)

**OTLP (OpenTelemetry):**
- Endpoint: `POST /api/otlp/logs`
- Format: OpenTelemetry Logs Protocol v1 (JSON)
- Converts OTLP resource/scope logs to Purl internal format
- Location: `lib/Purl/API/Controller/OTLP.pm`

**Syslog Ingest:**
- Endpoint: `POST /api/syslog/ingest`
- Protocols: RFC 5424 and RFC 3164
- Facility and severity mapping to internal log levels
- Location: `lib/Purl/API/Controller/Syslog.pm`

**Elasticsearch Compatibility:**
- Endpoint: `POST /api/_search`
- Translates basic Elasticsearch query DSL to ClickHouse SQL
- For tools that only support ES API
- Location: `lib/Purl/API/Controller/ESCompat.pm`

**Kubernetes Integration:**
- K8s audit log ingestion: `POST /api/k8s/audit`
- K8s health checks: `GET /api/k8s/health`
- Location: `lib/Purl/API/Controller/K8sAudit.pm`, `lib/Purl/API/Controller/K8sHealth.pm`

## Data Storage

**Databases:**
- ClickHouse 25.11+
  - Connection: HTTP API (port 8123)
  - Client: HTTP::Tiny (no ORM)
  - Storage driver: `lib/Purl/Storage/ClickHouse.pm`
  - Connects via `PURL_CLICKHOUSE_HOST`, `PURL_CLICKHOUSE_PORT`, `PURL_CLICKHOUSE_USER`, `PURL_CLICKHOUSE_PASSWORD`
  - Database: `purl` (configurable via `PURL_CLICKHOUSE_DATABASE`)
  - Tables: `logs`, `alerts`, `saved_searches`, `audit_logs`, `log_patterns`, `backups`, `dashboards`, `k8s_health`
  - Engine: MergeTree with TTL retention (`PURL_RETENTION_DAYS`, default 30 days)

**Backups:**
- Local filesystem: `/app/backups` (optional, configurable via `PURL_BACKUP_DIR`)
- S3 backup support (optional)
  - Enabled via `PURL_BACKUP_S3_ENABLED`
  - Bucket: `PURL_BACKUP_S3_BUCKET`
  - Region: `PURL_BACKUP_S3_REGION` (default `us-east-1`)
  - Credentials: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
  - Custom endpoint: `PURL_BACKUP_S3_ENDPOINT`
  - Location: `lib/Purl/Storage/ClickHouse/Backup.pm`

**File Storage:**
- Configuration files: `/app/config/` (Docker volume)
  - `settings.json` - Runtime configuration
  - `.instance_id` - Unique instance identifier
- User data: `/app/backups/` (optional persistent volume)

**Caching:**
- In-memory: Query result cache (no external service required)
- Redis (optional, for distributed caching)
  - Enabled via `PURL_REDIS_URL` (connection string)
  - Mode: `PURL_BROADCAST_MODE` - `auto` | `local` | `redis`
  - Location: `lib/Purl/Broadcast/Redis.pm`

## Authentication & Identity

**API Key Authentication:**
- Ingest endpoint `/api/logs` requires API key
- Header: `X-API-Key: {key}`
- Keys stored in config: `PURL_API_KEYS` (comma-separated)
- Middleware: `lib/Purl/API/Middleware/Auth.pm`

**Session Cookies:**
- Dashboard login via username/password
- Password hashing: Bcrypt with Crypt::Eksblowfish::Bcrypt
- Session secret: `PURL_SESSION_SECRET` (environment variable)
- Cookie-based sessions (Mojolicious built-in)

**JWT License Verification:**
- Algorithm: RS256 (RSA SHA-256)
- Token format: JWT containing plan, features, limits, expiry
- Verification: `lib/Purl/API/Middleware/License.pm`
- License server: `https://purlogs.com` (default, configurable via `PURL_LICENSE_API_URL`)
- Cache TTL: `PURL_LICENSE_CACHE_TTL` (default 3600 seconds)
- Free plan: No license key required (default features)

**LDAP/Active Directory (Enterprise):**
- Optional integration: `PURL_LDAP_ENABLED`
- Server: `PURL_LDAP_SERVER`, `PURL_LDAP_PORT` (default 389)
- Bind DN: `PURL_LDAP_BIND_DN`, `PURL_LDAP_BIND_PASSWORD`
- Search: `PURL_LDAP_SEARCH_BASE`, `PURL_LDAP_SEARCH_FILTER`
- TLS: `PURL_LDAP_TLS_ENABLED`, `PURL_LDAP_TLS_VERIFY` (require/optional)
- Attributes: user (`PURL_LDAP_USER_ATTR`), email (`PURL_LDAP_MAIL_ATTR`), groups (`PURL_LDAP_GROUP_ATTR`)
- Location: `lib/Purl/API/Middleware/LDAP.pm`

**SAML 2.0 (Enterprise SSO):**
- Optional integration: `PURL_SAML_ENABLED`
- Entity ID: `PURL_SAML_ENTITY_ID`
- IdP endpoint: `PURL_SAML_IDP_ENTITY_ID`, `PURL_SAML_IDP_SSO_URL`, `PURL_SAML_IDP_SLO_URL`
- IdP certificate: `PURL_SAML_IDP_CERT`
- ACS URL: `PURL_SAML_ACS_URL`
- Name ID format: `PURL_SAML_NAME_ID_FORMAT` (default `emailAddress`)
- Request signing: `PURL_SAML_SIGN_REQUESTS`, certificates `PURL_SAML_SP_CERT`, `PURL_SAML_SP_KEY`
- Attributes: username (`PURL_SAML_USERNAME_ATTR`), groups (`PURL_SAML_GROUPS_ATTR`)
- Location: `lib/Purl/API/Middleware/SAML.pm`

## Alerts & Notifications

**Alert Channels:**

**Telegram:**
- Enabled: `PURL_TELEGRAM_BOT_TOKEN` (Telegram Bot API token)
- Chat ID: `PURL_TELEGRAM_CHAT_ID`
- SDK: HTTP::Tiny (raw HTTP POST to Telegram API)
- Location: `lib/Purl/Alert/Telegram.pm`

**Slack:**
- Enabled: `PURL_SLACK_WEBHOOK_URL` (Incoming Webhook)
- Optional channel override: `PURL_SLACK_CHANNEL`
- SDK: HTTP::Tiny (raw HTTP POST to Slack)
- Location: `lib/Purl/Alert/Slack.pm`

**Webhook (Generic):**
- URL: `PURL_ALERT_WEBHOOK_URL`
- Auth token: `PURL_ALERT_WEBHOOK_TOKEN` (sent in Authorization header)
- Format: JSON POST with alert details
- Location: `lib/Purl/Alert/Webhook.pm`

**Alert Management:**
- CRUD endpoints: `lib/Purl/API/Controller/Alerts.pm`
- Storage: ClickHouse table `alerts`
- Pattern-based triggers: `lib/Purl/Storage/ClickHouse/Patterns.pm`

## AI & LLM Integration

**Providers Supported:**
- OpenAI (default) - API endpoint: `api.openai.com/v1/`
- Anthropic - API endpoint: `api.anthropic.com/v1/`
- Google Gemini - API endpoint: `generativelanguage.googleapis.com/`
- Ollama (self-hosted) - Custom base URL: `PURL_AI_BASE_URL`

**Configuration:**
- Provider: `PURL_AI_PROVIDER` (openai | anthropic | gemini | ollama)
- API Key: `PURL_AI_API_KEY`
- Model: `PURL_AI_MODEL` (empty = provider default)
- Base URL: `PURL_AI_BASE_URL` (for self-hosted or custom endpoints)
- Cache TTL: `PURL_AI_CACHE_TTL` (default 300 seconds)

**Capabilities:**
- Natural language to SQL conversion: `POST /api/ai/query`
- Log analysis & summarization: `POST /api/ai/analyze`
- Error explanation: `POST /api/ai/explain`
- Location: `lib/Purl/API/Controller/AI.pm`, `lib/Purl/AI/*.pm`

**Implementation:**
- Factory pattern: `lib/Purl/AI/Factory.pm`
- Provider base: `lib/Purl/AI/Provider/Base.pm`
- HTTP client: HTTP::Tiny (all providers use HTTP)

## Monitoring & Observability

**Health Checks:**
- Endpoint: `GET /api/health`
- Docker healthcheck: `curl -f http://localhost:3000/api/health`
- Interval: 30s, timeout: 10s, retries: 3, start period: 15s

**Metrics & Prometheus:**
- Endpoint: `GET /api/metrics`
- Format: Prometheus text format
- Tracks: requests total, errors, logs ingested, query duration, latencies
- Location: `lib/Purl/API/Controller/Analytics.pm`

**Audit Logging:**
- Table: `audit_logs` in ClickHouse
- Tracks: user actions, config changes
- Location: `lib/Purl/API/Controller/Audit.pm`

**Logging:**
- Framework: Perl `warn`/`die` (printed to STDOUT/STDERR)
- Docker: JSON file logging driver (max 10m per file, 3 files retained)
- Levels: Built-in (not structured, app is a log aggregation system)

## CI/CD & Deployment

**Hosting:**
- Docker Compose (development/small production)
- Docker image: `ismoilovdev/purl:${PURL_IMAGE_TAG:-latest}`
- Image registry: Docker Hub (ismoilovdev/purl)
- Optional: Kubernetes with Helm chart (`chart/` directory)

**CI Pipeline:**
- GitHub Actions (`.github/workflows/`)
- Build triggers: Push to `main` → `:latest`, push to `dev` → `:dev`
- Build: Dockerfile with multi-stage Perl + Node setup
- Push: Docker Hub auto-push on success

**Orchestration:**
- Docker Compose: `docker-compose.yml` (Purl + ClickHouse)
- Volume binding: `./config:/app/config` (persistent settings)
- Network: `purl-network` bridge
- Memory limits: 1G limit, 256M reservation

## Live Streaming & Broadcasting

**WebSocket Streaming:**
- Endpoint: `WS /api/logs/stream`
- Format: JSON log events
- Broadcasting backend: Local (in-process) or Redis
- Mode config: `PURL_BROADCAST_MODE` (auto/local/redis)
- Location: `lib/Purl/Broadcast/*.pm`

**Log Streaming:**
- Live tail: Push logs to connected WebSocket clients
- Pub/sub pattern: Channel-based subscription
- Local mode: In-memory subscriber map (single-process)
- Redis mode: Distributed pub/sub for multi-process/cluster

## Environment Configuration

**Required env vars for startup:**
- `PURL_CLICKHOUSE_HOST` - ClickHouse server hostname
- `PURL_CLICKHOUSE_PORT` - ClickHouse HTTP port (8123)
- `PURL_CLICKHOUSE_USER` - Database user
- `PURL_CLICKHOUSE_PASSWORD` - Database password
- `PURL_CLICKHOUSE_DATABASE` - Database name (default `purl`)
- `PURL_API_KEYS` - Comma-separated API keys for ingest auth
- `PURL_PORT` - Server port (default 3000)
- `PURL_HOST` - Bind address (default 0.0.0.0)

**Optional vars:**
- License: `PURL_LICENSE_KEY`, `PURL_LICENSE_PUBLIC_KEY`, `PURL_LICENSE_API_URL`
- Retention: `PURL_RETENTION_DAYS` (default 30)
- Alerts: `PURL_TELEGRAM_*`, `PURL_SLACK_*`, `PURL_ALERT_WEBHOOK_*`
- Auth: `PURL_LDAP_*` (LDAP), `PURL_SAML_*` (SAML)
- Backup: `PURL_BACKUP_*`, `AWS_*` (S3)
- Redis: `PURL_REDIS_URL`, `PURL_BROADCAST_MODE`
- AI: `PURL_AI_PROVIDER`, `PURL_AI_API_KEY`, `PURL_AI_MODEL`, `PURL_AI_BASE_URL`

**Secrets location:**
- Environment variables (recommended for Docker)
- Config file: `/app/config/settings.json` (no secrets stored, config only)
- Credentials file: `/opt/purl/.credentials` (auto-generated on deployment)

---

*Integration audit: 2026-03-10*
