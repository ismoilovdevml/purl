# Requirements: Purl — Quality & Completeness Milestone

**Defined:** 2026-03-10
**Core Value:** Every backend feature has a working UI, every code path is tested, and the system is production-ready with no known bugs.

## v1 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Security & Infrastructure

- [ ] **SEC-01**: CSRF token enforcement on all POST/PUT/DELETE endpoints via Base.pm safe_execute pre-hook
- [ ] **SEC-02**: InMemory storage mock moved to t/lib/ with method parity test against real storage interface
- [ ] **SEC-03**: Typed exception classes (Purl::Error::NotFound, Purl::Error::Validation) in Base.pm safe_execute
- [ ] **SEC-04**: Automated test that POSTs to every mutating endpoint without CSRF token and asserts 403

### Refactoring

- [ ] **REF-01**: Settings.pm (1,121 lines) split into 4 domain controllers: DatabaseSettings, NotificationSettings, AuthSettings, IntegrationSettings
- [ ] **REF-02**: Settings::Base helpers extracted for shared callback and config management
- [ ] **REF-03**: RateLimit extracted from Middleware::Auth into standalone Middleware::RateLimit with cleanup job
- [ ] **REF-04**: Purl::Validation module extracted from Storage::ClickHouse::Query role for standalone field validation
- [ ] **REF-05**: Route inventory test that validates all registered routes match their controllers

### Test Coverage

- [ ] **TST-01**: Test file for Controller::Pipeline — regex precompilation, rule CRUD, validation
- [ ] **TST-02**: Test file for Controller::Dashboard — widget execution, concurrent queries
- [ ] **TST-03**: Test file for Controller::Config — cache clear, cache invalidation
- [ ] **TST-04**: Test file for Controller::AI — provider init, query execution paths
- [ ] **TST-05**: Test file for Controller::ESCompat — Elasticsearch-compatible query translation
- [ ] **TST-06**: Test file for Controller::OTLP — protobuf/JSON ingest validation
- [ ] **TST-07**: Test file for Controller::Syslog — UDP/TCP syslog format parsing
- [ ] **TST-08**: Depth verification and expansion of K8sAudit and K8sHealth tests
- [ ] **TST-09**: Storage failover tests — ClickHouse unavailable at startup, connection timeout recovery
- [ ] **TST-10**: Alert edge case tests — deduplication, regex with special chars, zero-match condition
- [ ] **TST-11**: Settings persistence tests — file locking, atomic writes, concurrent update handling
- [ ] **TST-12**: Devel::Cover integrated and baseline coverage measurement established

### UI Completion — P1

- [ ] **UI-01**: Notifier status panel in NotificationSettings — shows which channels (Telegram, Slack, Webhook) are configured and reachable via /api/analytics/notifiers
- [ ] **UI-02**: Circuit breaker state displayed in AboutSettings from /api/health response
- [ ] **UI-03**: Pipeline dry-run test wired in PipelineSettings — showTestModal connected to real test endpoint
- [ ] **UI-04**: Cache-clear button in admin UI wired to /api/config/clear-cache endpoint

### UI Completion — P2

- [ ] **UI-05**: Ingest sources status panel showing last-received timestamp and log count per protocol (OTLP, Syslog, K8s audit, HTTP)
- [ ] **UI-06**: Audit log export — CSV/JSON download button in AuditSettings
- [ ] **UI-07**: K8s audit event stream wired in K8sPage alongside existing PodStatusPanel
- [ ] **UI-08**: Alert last-fired display in AlertsPanel — shows last evaluation result per rule

### Frontend Testing

- [ ] **FE-01**: Vitest + @testing-library/svelte 5.x setup with vitest.config.js
- [ ] **FE-02**: Store unit tests for critical stores (auth.js, logs.js, license.js, settings.js)
- [ ] **FE-03**: Playwright baseURL changed from hardcoded IP to env var for CI compatibility

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Alert System

- **ALR-01**: Alert history table with ClickHouse storage schema
- **ALR-02**: New alert delivery channels (PagerDuty, OpsGenie)

### Data Management

- **DAT-01**: Log export to CSV/S3 with streaming backend endpoint
- **DAT-02**: Per-service data retention rules with schema changes

### UI Enhancements

- **UIE-01**: Pattern trend sparklines per pattern in PatternsSidebar
- **UIE-02**: Password strength indicator (client-side entropy feedback)
- **UIE-03**: Saved search sharing toggle

### Architecture

- **ARC-01**: Server.pm package globals migration to instance attributes
- **ARC-02**: Frontend api/ layer extraction from stores
- **ARC-03**: Router.svelte extraction from App.svelte
- **ARC-04**: Async ClickHouse HTTP client migration

## Out of Scope

| Feature | Reason |
|---------|--------|
| New alert delivery channels (PagerDuty, OpsGenie) | New functionality, not hardening |
| Log export/download to CSV | Requires new streaming backend endpoint |
| Per-service data retention rules | Requires schema changes and new settings UI |
| Multi-tenancy quota UI | NamespaceScope incomplete; milestone on its own |
| Mobile-responsive redesign | Desktop-first is intentional |
| New features beyond existing backend capabilities | This milestone is quality-focused |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SEC-01 | Phase ? | Pending |
| SEC-02 | Phase ? | Pending |
| SEC-03 | Phase ? | Pending |
| SEC-04 | Phase ? | Pending |
| REF-01 | Phase ? | Pending |
| REF-02 | Phase ? | Pending |
| REF-03 | Phase ? | Pending |
| REF-04 | Phase ? | Pending |
| REF-05 | Phase ? | Pending |
| TST-01 | Phase ? | Pending |
| TST-02 | Phase ? | Pending |
| TST-03 | Phase ? | Pending |
| TST-04 | Phase ? | Pending |
| TST-05 | Phase ? | Pending |
| TST-06 | Phase ? | Pending |
| TST-07 | Phase ? | Pending |
| TST-08 | Phase ? | Pending |
| TST-09 | Phase ? | Pending |
| TST-10 | Phase ? | Pending |
| TST-11 | Phase ? | Pending |
| TST-12 | Phase ? | Pending |
| UI-01 | Phase ? | Pending |
| UI-02 | Phase ? | Pending |
| UI-03 | Phase ? | Pending |
| UI-04 | Phase ? | Pending |
| UI-05 | Phase ? | Pending |
| UI-06 | Phase ? | Pending |
| UI-07 | Phase ? | Pending |
| UI-08 | Phase ? | Pending |
| FE-01 | Phase ? | Pending |
| FE-02 | Phase ? | Pending |
| FE-03 | Phase ? | Pending |

**Coverage:**
- v1 requirements: 32 total
- Mapped to phases: 0
- Unmapped: 32 ⚠️

---
*Requirements defined: 2026-03-10*
*Last updated: 2026-03-10 after initial definition*
