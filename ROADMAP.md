# Purl Roadmap

## Current State (v0.2)

```
✅ Implemented    🔄 In Progress    ❌ Planned
```

### Core Features
- ✅ Log ingestion via HTTP API
- ✅ KQL-like search syntax
- ✅ Field statistics (level, service, host)
- ✅ Time histogram
- ✅ Docker auto-collection (Vector)
- ✅ Dark theme dashboard
- ✅ WebSocket live tail
- ✅ Saved searches
- ✅ Alerts/Notifications (browser, webhook, Slack)
- ❌ Custom dashboards

### Performance
- ✅ ClickHouse MergeTree storage
- ✅ Buffered inserts (batch 1000)
- ✅ Connection pooling (HTTP::Tiny keep_alive)
- ✅ Query caching (in-memory with TTL)
- ✅ ZSTD compression
- ✅ LowCardinality for categorical fields
- 🔄 Pagination (basic LIMIT/OFFSET)

### Security
- ✅ Basic Auth
- ✅ API Key authentication
- ✅ Rate limiting (1000 req/min per IP)
- ❌ OAuth/LDAP integration
- ❌ RBAC (role-based access)
- ❌ Audit logging

### Observability
- ✅ Health endpoint with details
- ✅ Prometheus metrics (/api/metrics)
- ❌ Distributed tracing
- ❌ Self-monitoring dashboard

### Scalability
- ✅ Single node deployment
- ❌ Horizontal scaling
- ❌ ClickHouse clustering
- ❌ Load balancing
- ❌ Kafka/Redis buffer

---

## Phase 1: Custom Dashboards (v0.3)

### Dashboard Builder
- Drag-and-drop widget placement
- Multiple visualization types (table, chart, gauge)
- Dashboard templates
- Share dashboards via URL

### Visualization Widgets
- Log count over time (line/bar)
- Error rate gauge
- Top N services/hosts
- Log stream (real-time)

---

## Phase 2: Advanced Security (v0.4)

### Authentication
- OAuth 2.0 / OIDC support
- LDAP/Active Directory integration
- MFA support

### Authorization
- Role-based access control (RBAC)
- Field-level permissions
- Query restrictions per role

### Compliance
- Audit logging
- Data masking for sensitive fields
- GDPR compliance tools

---

## Phase 3: Scalability (v0.5)

### High Availability
- Multiple Purl instances
- Load balancer integration
- Session sharing (Redis)

### Data Pipeline
- Kafka integration
- Redis buffer for burst traffic
- Dead letter queue

### ClickHouse Clustering
- Sharded tables
- Replicated tables
- Cross-datacenter replication

---

## Phase 4: Advanced Features (v1.0)

### Machine Learning
- Anomaly detection
- Log pattern clustering
- Predictive alerts

### Integrations
- PagerDuty
- Opsgenie
- Telegram
- Email notifications

### Multi-tenancy
- Workspace isolation
- Per-tenant retention policies
- Usage quotas

---

## Tech Debt & Improvements

### Code Quality
- ✅ Perl::Critic compliance
- ✅ ESLint + Svelte A11y compliance
- ❌ Unit tests (Perl)
- ❌ Integration tests
- ❌ E2E tests (Playwright)

### Documentation
- ✅ README with quick start
- ✅ Deployment guide
- ❌ API documentation (OpenAPI)
- ❌ Architecture documentation
- ❌ Contributing guide

### DevOps
- ✅ Docker Compose deployment
- ✅ Kubernetes manifests
- ❌ Helm chart refinement
- ❌ Terraform modules
- ❌ CI/CD pipeline
