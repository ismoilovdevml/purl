# Feature Research

**Domain:** Self-hosted log aggregation platform (hardening milestone)
**Researched:** 2026-03-10
**Confidence:** HIGH — based on direct codebase analysis of 25+ controllers, 40+ UI components, 36 test files, and `.planning/codebase/` documentation

---

## Context: This Is a Quality Milestone

This is not a greenfield feature list. The goal is production-readiness of an existing platform. The framing is: "which existing backend capabilities have no UI, which UI flows are incomplete, and where does test coverage need to grow?" New functionality is explicitly out of scope.

The 25 backend controllers and their current UI coverage status:

| Controller | UI Component Exists | Coverage Quality |
|---|---|---|
| Logs | QueryPage, LogTable, LogDetail | GOOD |
| Alerts | AlertsPanel | GOOD |
| AlertTemplates | AlertTemplateGallery | GOOD |
| Auth | LoginPage | GOOD |
| Dashboard | DashboardPage | GOOD |
| Patterns | PatternsSidebar | GOOD |
| SavedSearches | SavedSearches | GOOD |
| Traces | TracesPage | GOOD |
| Agents | AgentsSettings | GOOD |
| Backup | BackupSettings | GOOD |
| Pipeline | PipelineSettings | PARTIAL — rule editor is primitive |
| Analytics | AnalyticsPage | PARTIAL — notifiers endpoint unused |
| AI | AIAnalysisPanel, AIQueryBar | PARTIAL — no AI provider config test coverage |
| Audit | AuditSettings | PARTIAL — stats panel exists, no export |
| Stats | Used internally by QueryPage | PARTIAL — db_stats not surfaced to users |
| System (health/metrics) | AboutSettings | PARTIAL — metrics/json used, circuit_breaker not shown |
| Clusters | ClusterSelector | PARTIAL — selector only, no cluster health view |
| K8sAudit | K8sPage | PARTIAL — PodStatusPanel exists, K8s audit stream not displayed |
| K8sHealth | K8sPage | PARTIAL — limited panel |
| ESCompat | No UI component | NONE — pure API compat layer, no admin toggle |
| OTLP | No UI component | NONE — ingest endpoint, no source status |
| Syslog | No UI component | NONE — ingest endpoint, no source status |
| Config | No dedicated page | NONE — cache clear endpoint has no UI button |
| Settings | SettingsPage with sub-pages | GOOD (structure exists) |
| Base | N/A (parent class) | N/A |

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features that users of any production-grade log tool assume are present. Missing them makes the product feel incomplete or untrustworthy.

| Feature | Why Expected | Complexity | Notes |
|---|---|---|---|
| UI for all ingest sources (OTLP, Syslog, K8s audit) | Users need to verify their shippers are working; blind ingest with no confirmation is a support problem | MEDIUM | Backend controllers exist; need a "Sources" status panel showing last-received timestamp, log count, protocol. SourcesSettings.svelte exists but is minimal |
| Pipeline rule editor with live test | Pipeline processing is useless without the ability to craft and validate rules in-browser | MEDIUM | PipelineSettings.svelte has create/delete but no per-rule editing or in-place regex tester |
| Audit log export | Enterprise users need downloadable audit trails for compliance (SOC 2, ISO 27001) | LOW | AuditSettings.svelte shows the table; needs a CSV/JSON download button hitting `/api/audit` with no pagination limit |
| System health dashboard with circuit breaker state | Admins must know if the DB connection is degraded without SSH-ing to the container | LOW | AboutSettings.svelte calls `/api/health` and `/api/metrics/json` but does not surface `circuit_breaker` status. System.pm already returns it |
| Alert history and last-fired time | Without firing history, users cannot tell if an alert is working or silently broken | MEDIUM | No alert history table in AlertsPanel. Backend stores last-evaluated logic but no history trail |
| Notifier status panel | Admins need to see which notification channels (Telegram, Slack, Webhook) are configured and reachable | LOW | `/api/analytics/notifiers` endpoint exists and returns `{telegram: {configured: 1, name:...}}` but no UI consumes it. NotificationSettings.svelte exists but does not show connection status |
| Cache clear button in admin UI | Stale data after settings changes is a common complaint; cache clear must be one click | LOW | `/api/config/clear-cache` endpoint exists; no UI button wired to it anywhere |
| Password strength enforcement UI feedback | Browser-side feedback on weak passwords prevents support tickets | LOW | Auth.pm hashes and rejects weak passwords server-side; login/user forms have no client-side entropy indicator |
| User management CRUD with role display | Admins need to see all users, their roles, and last login without reading config.json | MEDIUM | UsersSettings.svelte exists but depth is unknown; must cover list, create, role assignment, password reset, delete |
| API key management with last-used metadata | API keys need lifecycle management (create, label, revoke, see when last used) | MEDIUM | ApiKeysSettings.svelte exists; needs last-used timestamp surfaced |
| Saved search sharing | Saved searches that only exist per-user reduce team value | LOW | Backend `saved_searches` table likely has an owner field; UI currently loads all saved searches, no sharing toggle |

### Differentiators (Competitive Advantage)

Features that, once the table stakes are solid, would give Purl an edge over Grafana Loki, Graylog, or a bare ClickHouse setup. These are **in-scope** for this milestone only where the backend already supports them and only the UI is missing.

| Feature | Value Proposition | Complexity | Notes |
|---|---|---|---|
| K8s audit event stream in UI | Most log tools require a separate K8s audit viewer; combining it with logs is a unique workflow | MEDIUM | K8sAudit.pm and K8sPage.svelte exist; K8sPage needs the audit event stream wired, not just pod status. PodStatusPanel.svelte is the only component |
| Pipeline dry-run with sample log | Letting devs paste a sample log and see exactly which pipeline rules fire and what fields get added is a strong DX win | MEDIUM | Pipeline.pm has a test endpoint; PipelineSettings.svelte has a `showTestModal` but it is not wired to real test execution |
| Pattern detection sidebar with trend | Showing how a log pattern's frequency changes over time (is this a new error or a known one?) differentiates from basic search | HIGH | PatternsSidebar.svelte exists; needs a sparkline trend per pattern |
| AI explain on any log line | One-click contextual explanation of a cryptic error message | LOW | AIExplainModal.svelte exists; needs to be available from LogDetail, not just the AI panel |

### Anti-Features (For This Milestone)

Features that seem like natural additions but are explicitly out of scope for this hardening milestone. Documenting them prevents scope creep.

| Anti-Feature | Why Requested | Why Problematic for This Milestone | Alternative |
|---|---|---|---|
| New alert delivery channels (PagerDuty, OpsGenie) | Common user request | Requires new backend modules and config UI — new functionality, not hardening | Defer to next feature milestone |
| Log export / download to CSV | Common user request | Backend has no export endpoint; would require streaming implementation | Listed in CONCERNS.md as missing critical feature; defer to feature milestone |
| Data retention rules per service | Admins want granular TTL | Requires schema changes and new settings UI — new functionality | Listed in CONCERNS.md; defer |
| Multi-tenancy quota UI | SaaS operators want per-tenant dashboards | NamespaceScope.pm is incomplete; full implementation is a milestone on its own | Defer |
| Mobile-responsive redesign | Some users ask for it | Dark-theme desktop-first layout is intentional; mobile changes break existing UI | Scope explicitly excluded in PROJECT.md |
| Svelte component test suite (Vitest) | Good engineering hygiene | Frontend tests (E2E via Playwright) already exist; adding Vitest requires tooling setup that is a distraction from backend hardening | E2E tests cover the critical paths; unit tests for Svelte defer until post-hardening |

---

## Feature Dependencies

```
[UI: Ingest Sources Panel]
    └──requires──> [Backend: Sources status aggregation from OTLP + Syslog + K8s controllers]
                       └──exists──> Already in respective controllers (last-received logic partial)

[UI: Pipeline Rule Editor]
    └──requires──> [Backend: Pipeline.pm test endpoint working correctly]
                       └──requires──> [Bug: Pipeline regex precompilation fixed]

[UI: Notifier Status Panel]
    └──requires──> [Backend: /api/analytics/notifiers endpoint — EXISTS]
    └──enhances──> [UI: Notification Settings page]

[UI: Alert History Table]
    └──requires──> [Backend: Alert history storage in ClickHouse — MISSING, needs schema]
    └──enhances──> [UI: AlertsPanel]

[UI: Cache Clear Button]
    └──requires──> [Backend: /api/config/clear-cache — EXISTS]

[UI: Circuit Breaker Status]
    └──requires──> [Backend: circuit_breaker_status() — EXISTS in System.pm response]
    └──enhances──> [UI: AboutSettings]

[Test: Controller coverage for Pipeline, Dashboard, Config]
    └──requires──> [Refactor: Settings.pm split into sub-controllers — CONCERNS.md blocker]

[Test: Storage failover tests]
    └──requires──> [Refactor: ClickHouse.pm circuit breaker isolation — CONCERNS.md]

[CSRF enforcement]
    └──requires──> [Fix: Base.pm safe_execute CSRF check — CONCERNS.md known bug]
    └──blocks──> [All POST endpoint tests being meaningful]
```

### Dependency Notes

- **Alert history requires schema work:** The backend has no `alert_history` table. Building alert history UI before the storage exists wastes effort. Decide: minimal history (in-memory last-N firings) or proper ClickHouse table.
- **Settings.pm refactor unlocks testability:** The 1,121-line Settings.pm makes it impossible to test individual settings sections without integration-test overhead. Splitting it is a prerequisite for achieving meaningful unit test coverage of settings endpoints.
- **CSRF bug blocks test validity:** If CSRF is not enforced on POST endpoints, tests that omit the CSRF token still pass. This means test coverage numbers are misleading — tests pass for the wrong reason.
- **Pipeline test endpoint is the gateway:** The pipeline dry-run UI feature depends on Pipeline.pm working correctly and the regex precompilation bug being fixed first.

---

## MVP Definition for This Milestone

This is a hardening milestone, so "MVP" means: minimum work to call the platform production-ready, not minimum to ship a new feature.

### Must Complete (Production-Ready Baseline)

- [ ] CSRF enforcement in Base.pm safe_execute — all POST/PUT/DELETE automatically protected
- [ ] Settings.pm split into sub-controllers (DatabaseSettings, AuthSettings, NotificationSettings, IntegrationSettings) — unlocks testability and reduces fragility
- [ ] Test coverage for all untested controllers: Pipeline, Dashboard, Config, AI, K8sAudit, K8sHealth, ESCompat, OTLP, Syslog — one test file per controller minimum
- [ ] Storage failover tests — ClickHouse unavailable during startup, connection timeout recovery
- [ ] Alert edge case tests — deduplication, regex with special chars, zero-match condition
- [ ] Settings persistence tests — file locking, atomic writes, concurrent update handling
- [ ] Wire `/api/analytics/notifiers` to NotificationSettings — shows which channels are active (LOW complexity, HIGH user value)
- [ ] Wire circuit_breaker state to AboutSettings — one field addition (LOW complexity, CRITICAL for ops)
- [ ] Add cache-clear button to admin UI — single API call wired to existing endpoint
- [ ] Fix pipeline dry-run in PipelineSettings — testSample is already in state, just needs the fetch call

### Complete After Core Hardening (v1.x)

- [ ] Ingest sources status panel — aggregate last-received per protocol (OTLP, Syslog, K8s audit, HTTP)
- [ ] Audit log export (CSV download) — frontend button, no backend change needed
- [ ] K8s audit event stream in K8sPage — wire K8sAudit.pm events to the existing K8s UI page
- [ ] Alert last-fired display — show last evaluation result in AlertsPanel without full history storage

### Defer to Next Milestone (v2+)

- [ ] Alert history table with ClickHouse storage — requires schema change
- [ ] Pattern trend sparklines — non-trivial query + visualization
- [ ] Per-service data retention rules — requires schema + settings UI
- [ ] Log export to CSV/S3 — requires streaming backend endpoint

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---|---|---|---|
| CSRF enforcement in Base.pm | HIGH (security) | LOW (10-20 lines) | P1 |
| Settings.pm split | HIGH (testability blocker) | HIGH (refactor 1121 lines) | P1 |
| Test: untested controllers (Pipeline, Dashboard, etc.) | HIGH (reliability) | MEDIUM (9 new test files) | P1 |
| Wire notifier status to UI | HIGH (ops visibility) | LOW (fetch + display) | P1 |
| Wire circuit breaker to AboutSettings | HIGH (ops visibility) | LOW (one field) | P1 |
| Pipeline dry-run test in UI | HIGH (DX) | LOW (wired state already exists) | P1 |
| Cache clear button | MEDIUM (ops usability) | LOW (single API call) | P1 |
| Storage failover tests | HIGH (availability) | MEDIUM (mock HTTP layer) | P1 |
| Alert edge case tests | MEDIUM (reliability) | MEDIUM (add subtests) | P2 |
| Settings persistence tests | MEDIUM (reliability) | MEDIUM (tempfile fixtures) | P2 |
| Ingest sources status panel | HIGH (operational UX) | MEDIUM (aggregate 3 controllers) | P2 |
| Audit log export button | MEDIUM (compliance) | LOW (fetch + download) | P2 |
| K8s audit stream in K8sPage | MEDIUM (feature completeness) | MEDIUM (wire existing endpoint) | P2 |
| Alert last-fired display | MEDIUM (user trust) | MEDIUM (in-memory last-N) | P2 |
| Password strength indicator (client-side) | LOW (UX) | LOW | P3 |
| Saved search sharing toggle | LOW (collaboration) | LOW | P3 |

**Priority key:**
- P1: Must complete for production-ready claim
- P2: Should complete in this milestone if P1 is done
- P3: Nice to have, can defer

---

## Test Coverage Gap Map

This section maps the specific test coverage gaps identified in CONCERNS.md and TESTING.md to actionable work items.

### Controllers With No Test File

| Controller | Test File | Risk |
|---|---|---|
| Pipeline | None | HIGH — regex precompilation bug, no validation coverage |
| Dashboard | None | HIGH — widget execution, concurrent queries |
| Config | None | MEDIUM — cache clear, no coverage of cache invalidation |
| AI | None | MEDIUM — provider init, query execution paths |
| K8sAudit | `t/k8s_audit.t` exists | LOW — verify coverage depth |
| K8sHealth | `t/k8s_health.t` exists | LOW — verify coverage depth |
| ESCompat | None | MEDIUM — Elasticsearch-compatible query translation |
| OTLP | None | MEDIUM — protobuf/JSON ingest validation |
| Syslog | None | MEDIUM — UDP/TCP syslog format parsing |

### Untested Behaviors in Existing Test Files

| Area | Gap | File to Fix |
|---|---|---|
| Auth: LDAP connection failure | No timeout/pool test | `t/middleware_ldap.t` |
| Auth: SAML malformed assertion | No edge case | `t/middleware_saml.t` |
| Storage: ClickHouse unavailable at startup | No failover test | New: `t/storage_failover.t` |
| Alerts: deduplication | No rapid-fire prevention test | `t/edge_cases_alerts.t` |
| Alerts: zero-match condition | Not tested | `t/edge_cases_alerts.t` |
| Settings: concurrent updates from two requests | No concurrency test | New: `t/settings_persistence.t` |
| Settings: callback exception during rebuild | No exception path | New: `t/settings_callbacks.t` |
| WebSocket: concurrent connection modifications | No test | New: `t/broadcast_race.t` (LOW — hard to test in Perl) |

---

## Sources

- Direct codebase analysis: `lib/Purl/API/Controller/` (25 controllers)
- Direct UI analysis: `web/src/components/` (40+ Svelte components)
- `.planning/codebase/CONCERNS.md` — known bugs, security issues, tech debt
- `.planning/codebase/TESTING.md` — test framework patterns and gaps
- `.planning/codebase/ARCHITECTURE.md` — system structure and data flows
- `.planning/PROJECT.md` — milestone scope and constraints
- Confidence: HIGH for all items — derived from direct code inspection, not inference

---

*Feature research for: Purl log aggregation platform — quality hardening milestone*
*Researched: 2026-03-10*
