# Codebase Concerns

**Analysis Date:** 2026-03-10

## Tech Debt

**Monolithic Storage Class:**
- Issue: `lib/Purl/Storage/ClickHouse.pm` is 1,316 lines with 10+ Moo role mixins. Single responsibility violated—queries, caching, alerts, backups, dashboards all mixed together.
- Files: `lib/Purl/Storage/ClickHouse.pm`
- Impact: Hard to test individual features, high cognitive load, difficult to parallelize work. Changes to one concern risk breaking others.
- Fix approach: Extract cache layer into separate class (`Purl::Storage::ClickHouse::Cache` is partially done but still coupled), move alert evaluation to dedicated processor, separate backup logic. Keep only query execution in main class.

**Settings Controller Over-Responsibilities:**
- Issue: `lib/Purl/API/Controller/Settings.pm` is 1,121 lines. Handles database settings, auth, LDAP, SAML, Slack, Telegram, backup, Redis config, K8s health settings, pipeline config, agents, all in one file.
- Files: `lib/Purl/API/Controller/Settings.pm`
- Impact: Difficult to modify individual setting handlers without risk of breaking unrelated code. Test suite required per setting.
- Fix approach: Split into separate controllers: `DatabaseSettings`, `AuthSettings`, `NotificationSettings`, `IntegrationSettings`. Each handles its own endpoints and callbacks.

**Session Secret Ephemeral on Restart:**
- Issue: `lib/Purl/API/Server.pm` lines 293-304 create session secrets that don't survive container restarts unless `PURL_SESSION_SECRET` env var is set. For multi-replica deployments, sessions will fail across container restarts.
- Files: `lib/Purl/API/Server.pm` (lines 293-304)
- Impact: User sessions break on pod restart, poor UX in Kubernetes deployments.
- Fix approach: Always persist session secret to `config/server.json` instead of ephemeral generation. Log warning if env var not set, but read from persistent storage first.

**Default Admin Credential Hard-Coded:**
- Issue: `lib/Purl/API/Server.pm` lines 317-326 create admin user with default password `admin` if no users exist and `PURL_ADMIN_PASSWORD` env var not set.
- Files: `lib/Purl/API/Server.pm` (lines 317-326)
- Impact: First deployment is accessible with weak credentials. Log warning is insufficient—should fail startup if running in production without explicit password.
- Fix approach: Require `PURL_ADMIN_PASSWORD` env var or force interactive setup on first boot. Never default to `admin/admin`.

**Weak Password Detection Logic:**
- Issue: `lib/Purl/API/Server.pm` lines 336-348 check against common weak passwords by hashing and comparing. This approach is CPU-intensive and only catches exact weak passwords, not variations.
- Files: `lib/Purl/API/Server.pm` (lines 336-348)
- Impact: False confidence—users might set similarly weak passwords that don't match the hardcoded list.
- Fix approach: Implement entropy check (require minimum 12-16 characters, mixed case, numbers). Or delegate to library like `Data::Validate::Password`.

**Validation Functions in Mixed Locations:**
- Issue: Validation functions (`_validate_field`, `_validate_level`, `_sanitize_identifier`) are scattered across `lib/Purl/Storage/ClickHouse/Query.pm` as role methods. No reusable validation module.
- Files: `lib/Purl/Storage/ClickHouse/Query.pm`
- Impact: Hard to unit test validation separately. New modules must mix the role to validate inputs. Duplication risk in other controllers.
- Fix approach: Extract into `lib/Purl/Validation.pm` with exported functions or methods. Test suite independently.

**CircularBuffer for Metrics Leaks Memory:**
- Issue: `lib/Purl/API/Server.pm` lines 68-73 pre-allocates 1,000 float slots for latency metrics. In long-running servers, this becomes unbounded if metrics grow.
- Files: `lib/Purl/API/Server.pm` (lines 68-73)
- Impact: Server memory grows proportionally with uptime and request volume.
- Fix approach: Implement actual circular buffer with fixed size, or move metrics to Redis-backed time series.

**Broadcast System Can Fall Back Silently:**
- Issue: `lib/Purl/API/Server.pm` lines 210-236 try Redis for broadcasting but silently fall back to local in-memory if Redis unavailable. Multi-replica deployments will lose real-time sync.
- Files: `lib/Purl/API/Server.pm` (lines 210-236)
- Impact: Dashboard updates won't propagate across replicas. Users see stale data.
- Fix approach: In cluster mode, fail startup if Redis is required but unavailable. Log which mode is active clearly.

---

## Known Bugs

**CSRF Token Verification Not Mandatory:**
- Symptoms: CSRF protection middleware exists but endpoints don't enforce it. Safe CSRF check only for POST/PUT/DELETE but no guarantee all mutable ops check it.
- Files: `lib/Purl/API/Middleware/Auth.pm` (lines 399-414)
- Trigger: Make POST request to `POST /api/v1/alerts` without `X-CSRF-Token` header—succeeds if authenticated.
- Workaround: Manually add check in each POST endpoint: `return $self->render_error($c, "CSRF token required", 403) unless $self->check_csrf($c);`
- Fix approach: Make `safe_execute` wrapper in `Base.pm` check CSRF automatically for non-GET requests.

**License Info Cached Without Timeout:**
- Symptoms: License info cached in `lib/Purl/API/Middleware/License.pm` with expiry, but cache key generation doesn't account for instance variation. If instance activation changes, cache not invalidated.
- Files: `lib/Purl/API/Middleware/License.pm` (lines 27-35, 318-328)
- Trigger: Activate license on Instance A, license info cached. Restart into Instance B, old license cached, plan features don't reflect.
- Workaround: Restart container or clear cache manually.
- Fix approach: Include instance ID in cache key, or reduce cache TTL to 5min (currently 1hour).

**SQL Injection Safe But String Escaping May Not Cover All Cases:**
- Symptoms: Parameterized queries via `_quote_string` are safe for most cases, but any adhoc SQL construction could bypass validation.
- Files: `lib/Purl/Storage/ClickHouse/Query.pm` (lines 30-36)
- Trigger: If new code constructs SQL without using `_quote_string` for all string values, injection possible.
- Workaround: Always use `_quote_string` for user inputs. Use parameterized queries when possible.
- Fix approach: Use ClickHouse query builder library or enforce regex checks for raw SQL.

---

## Security Considerations

**Password Hashing Cost Parameter Fixed at 12:**
- Risk: Bcrypt cost 12 is reasonable (2024 standard is 10-12), but if CPUs become much faster or `Crypt::Eksblowfish::Bcrypt` has a bug, all passwords at same strength.
- Files: `lib/Purl/API/Middleware/Auth.pm` (lines 98-100)
- Current mitigation: Fixed high cost, periodic password rotation policy recommended.
- Recommendations: Make cost configurable via env var. Implement password rotation prompts every 90 days. Use argon2 if available (more resistant to GPU attacks).

**API Keys Stored in Plain Text in Config:**
- Risk: API keys and webhook secrets stored in `config/settings.json` without encryption. If config volume is compromised, all external integrations accessible.
- Files: `lib/Purl/Config.pm` (entire file — no encryption), `lib/Purl/API/Controller/Settings.pm` (lines 91-110)
- Current mitigation: File permissions set to 0600, container runs as non-root user.
- Recommendations: Implement envelope encryption (master key in env var, rotate separately). Use HashiCorp Vault for secrets. At minimum, encrypt sensitive fields at rest.

**JWT RS256 License Verification:**
- Risk: License JWT verified with public key only. If public key compromised or attacker can intercept activation API, license can be forged.
- Files: `lib/Purl/API/Middleware/License.pm` (entire file)
- Current mitigation: License key pinning in code, activation requires live API call to validate signature.
- Recommendations: Use sealed envelope (encrypt JWT with AES-256 using instance-specific key). Implement license revocation list (CRL) with periodic updates. Log all license activation events.

**SAML/LDAP Passwords in Config:**
- Risk: LDAP bind password and SAML SP key stored in config file without encryption. Allows full LDAP/SAML takeover if config leaked.
- Files: `lib/Purl/API/Middleware/LDAP.pm`, `lib/Purl/API/Middleware/SAML.pm`
- Current mitigation: Config volume permissions, container user isolation.
- Recommendations: Read sensitive fields from env vars only (PURL_LDAP_BIND_PASSWORD, PURL_SAML_SP_KEY). Never write to config file.

**No Rate Limiting on Ingest API:**
- Risk: `lib/Purl/API/Controller/Logs.pm` POST endpoint has no rate limiting. An attacker can flood logs and exhaust ClickHouse storage.
- Files: `lib/Purl/API/Controller/Logs.pm` (lines 1-50)
- Current mitigation: HTTP server timeout, ClickHouse query timeout.
- Recommendations: Implement IP-based rate limiting (100req/sec per API key). Return 429 Too Many Requests. Add burst bucket algorithm.

---

## Performance Bottlenecks

**ClickHouse HTTP API Blocking Requests:**
- Problem: Every log search, pattern query, alert evaluation blocks Mojolicious worker. HTTP::Tiny is synchronous, no connection pooling optimization.
- Files: `lib/Purl/Storage/ClickHouse.pm` (lines 87-98)
- Cause: HTTP::Tiny->new() per instance with keep_alive, but no async. Large queries (seconds) freeze worker.
- Improvement path: (1) Implement async using Mojo::Promise + Mojolicious::Plugin::Config. (2) Add configurable query timeout with graceful degradation. (3) Cache frequent queries aggressively (already done, but TTL may be too short).

**Materialized Views Full Recalculation:**
- Problem: `lib/Purl/Storage/ClickHouse.pm` lines 429-455 create materialized views for level/service stats. Every insert re-aggregates entire partition.
- Files: `lib/Purl/Storage/ClickHouse.pm` (lines 429-455)
- Cause: Views are SummingMergeTree, not incremental. High-cardinality services cause slow insertions.
- Improvement path: (1) Switch to AggregatingMergeTree with -State/-Merge functions for true incremental aggregation. (2) Pre-aggregate at ingest time in Perl. (3) Add sampling for high-volume periods.

**Field Statistics Cardinality Explosion:**
- Problem: `lib/Purl/Storage/ClickHouse.pm` lines 712-757 query distinct values for each field with no limit. If `host` has 10k unique values, query takes seconds.
- Files: `lib/Purl/Storage/ClickHouse.pm` (lines 712-757)
- Cause: No cardinality estimate before querying. Full table scan.
- Improvement path: (1) Add `LIMIT 1000` to cardinality queries. (2) Return estimated cardinality from `system.parts_columns`. (3) Cache for hours.

**Alert Evaluation Full Table Scan Per Alert:**
- Problem: `lib/Purl/Storage/ClickHouse/Alerts.pm` evaluates each alert with separate queries. With 100 alerts, 100+ queries per minute.
- Files: `lib/Purl/Storage/ClickHouse/Alerts.pm` (lines 119-175)
- Cause: Each alert runs its own WHERE clause. No consolidated query.
- Improvement path: (1) Batch alert evaluation into single UNION ALL query. (2) Move to continuous pipeline (similar to Kafka Streams). (3) Add alert index for fast lookup of active rules.

**Dashboard Widget Queries Unoptimized:**
- Problem: Dashboard generates multiple sub-queries for each widget (counter, charts, logs). Dashboard page with 6 widgets = 12+ ClickHouse queries sequentially.
- Files: `lib/Purl/API/Controller/Dashboard.pm`, `lib/Purl/Storage/ClickHouse/Dashboard.pm`
- Cause: Widgets query independently. No query consolidation.
- Improvement path: (1) Fetch all widget data in single query with subqueries. (2) Cache dashboard state for 30s. (3) Move to dashboard-specific materialized view.

---

## Fragile Areas

**Auth Middleware State Cleanup:**
- Files: `lib/Purl/API/Middleware/Auth.pm` (lines 35-44, 281-297)
- Why fragile: Failed login tracking and rate limit state stored in Perl hash. No automatic cleanup. Long-running servers accumulate orphaned entries. If server reaches 1000s of entries, lookup becomes O(n).
- Safe modification: (1) Add periodic cleanup job (every 5min) that purges old entries. (2) Use bounded LRU cache. (3) Move state to Redis.
- Test coverage: Only manual test in `t/06_middleware_auth.t`. No edge cases for cleanup race conditions.

**Settings Callback Hell:**
- Files: `lib/Purl/API/Controller/Settings.pm` (lines 24-62)
- Why fragile: Settings controller takes 6+ callbacks (`rebuild_notifiers`, `rebuild_storage`, `reload_license`, `rebuild_ldap`, `rebuild_saml`). If callbacks have side effects or exceptions, entire settings update fails. No transaction semantics.
- Safe modification: (1) Wrap each callback in try/catch. (2) Implement rollback (save old state before update). (3) Return detailed error per callback.
- Test coverage: No test for callback exceptions. `t/controller/settings.t` exists but minimal.

**WebSocket Broadcasting Race Condition:**
- Files: `lib/Purl/API/Server.pm` (lines 54-55)
- Why fragile: Package-level `$websockets` array and `$broadcaster` shared across all requests. No lock. If one request modifies while another reads, iterator invalidation possible.
- Safe modification: (1) Use thread-safe data structure (unlikely in Perl). (2) Add explicit locking around read/write. (3) Move to Redis pub/sub (already optional but not enforced).
- Test coverage: No test for concurrent websocket updates.

**LDAP Connection Timeout Not Enforced:**
- Files: `lib/Purl/API/Middleware/LDAP.pm` (entire file)
- Why fragile: LDAP connect timeout configurable but default may be too high (blocking requests). No connection pooling, each auth creates new connection.
- Safe modification: (1) Add connection pool with max 10 concurrent. (2) Set timeout to 5s max. (3) Implement reconnect with exponential backoff.
- Test coverage: Test exists (`t/middleware_ldap.t`) but no timeout/pool tests.

**Pipeline Rule Regex Compilation Not Cached:**
- Files: `lib/Purl/Pipeline/Engine.pm` (lines 200-240)
- Why fragile: Every log passes through pipeline rules. If rule regex invalid, exception during processing. No regex precompilation.
- Safe modification: (1) Precompile all regex patterns at startup. (2) Validate regex syntax before storing. (3) Cache compiled patterns with weak references.
- Test coverage: `t/01_` unit tests exist but no performance test for high-throughput pipelines.

---

## Scaling Limits

**In-Memory Metrics Circular Buffer:**
- Current capacity: 1,000 latency samples
- Limit: With 1000 req/sec, buffer fills in 1 second. Only last 1 second of metrics retained. Metrics page shows no historical trend.
- Scaling path: (1) Increase to 10,000 (5-10 second window). (2) Move to Redis for cross-replica visibility. (3) Aggregate to ClickHouse metrics table.

**Local Broadcast No Cross-Replica Sync:**
- Current capacity: Single server only
- Limit: If deploying 3+ replicas, dashboard updates (new alerts, saved searches) won't propagate. Users on replica A don't see changes made on replica B for 30+ seconds (until next cache refresh).
- Scaling path: (1) Make Redis required in cluster mode. (2) Implement pub/sub on dashboard updates. (3) Add WebSocket federation across replicas.

**ClickHouse Single Node Retention:**
- Current capacity: 30 days (configurable)
- Limit: Each day of logs can be 10GB+. 30 days = 300GB+. Single node ClickHouse can handle, but replication setup for HA not documented.
- Scaling path: (1) Implement ClickHouse cluster deployment (Zookeeper + replication). (2) Add data tiering (hot 7d in fast storage, warm 7-30d in slower storage). (3) Implement distributed queries across multiple nodes.

**API Key Validation No Caching:**
- Current capacity: 1,000 req/sec per server
- Limit: Each ingest request validates API key by lookup in config. Config file I/O or in-memory hash lookup. With 10k+ keys, lookup becomes slow.
- Scaling path: (1) Cache validated keys in Redis (5min TTL). (2) Use Bloom filter for fast negative caching. (3) Move keys to dedicated auth service.

**Alert Evaluation Single-Threaded:**
- Current capacity: 100 alerts
- Limit: All alerts evaluated sequentially every 5min. If evaluating takes 30sec, next batch starts while previous still running. Cascading delays.
- Scaling path: (1) Parallelize alert evaluation across worker threads. (2) Move to event-driven (ClickHouse triggers → Kafka → processor). (3) Distribute to separate alert service.

---

## Dependencies at Risk

**Mojolicious Lite (Lightweight Framework):**
- Risk: Mojolicious::Lite is appropriate for small projects but Purl has 20+ controllers and growing. Lite constrains structure. Full Mojolicious migration would be effort.
- Impact: Adding features becomes harder without proper routing/middleware organization.
- Migration plan: (1) Keep Lite as is (acceptable for current size). (2) If exceeding 30 controllers, migrate to Mojolicious full with separate route files. (3) No breaking changes required.

**JSON::XS Direct Usage (No Abstraction):**
- Risk: Floating point precision loss in BigInt conversions. Some fields (trace_id as string, not int) safe, but if IDs become numeric, precision lost.
- Impact: Large trace IDs (>2^53) will lose precision when converted to JSON.
- Migration plan: (1) Always store IDs as strings, never numeric. (2) Validate in tests that all IDs are strings in JSON output. (3) Consider MojoX::JSON::RPC or similar for strict typing.

**HTTP::Tiny (No Connection Pooling Library):**
- Risk: HTTP::Tiny is minimal, no keep-alive optimization. Each ClickHouse query creates new TCP connection (mitigated by keep_alive flag but not ideal).
- Impact: High latency on slow networks, connection establishment overhead.
- Migration plan: (1) Evaluate LWP::UserAgent or curl_easy. (2) No immediate migration needed (current performance acceptable). (3) Consider async library if Mojolicious parallelization needed later.

**Crypt::Eksblowfish::Bcrypt (Old Crypto Library):**
- Risk: Bcrypt is standard but Eksblowfish implementation may have bugs. Argon2 is newer and resistant to GPU attacks.
- Impact: Password hashing slightly weaker than modern alternatives.
- Migration plan: (1) Evaluate Crypt::Argon2 availability. (2) Support both during transition (detect and upgrade on login). (3) No immediate risk (bcrypt is industry-standard).

---

## Missing Critical Features

**No Multi-Tenancy or Namespace Isolation:**
- Problem: Single Purl instance serves all logs globally. No per-tenant quotas, separate role-based views, or data isolation.
- Blocks: Can't offer SaaS. Can't restrict users to subset of logs.
- Fix approach: (1) Add tenant_id to logs table and all queries. (2) Implement namespace-aware auth (partially done in `lib/Purl/API/Middleware/NamespaceScope.pm` but incomplete). (3) Add tenant quotas (daily ingest, retention).

**No Audit Trail for Settings Changes:**
- Problem: When admin changes database credentials, alerts config, or license, no log of who changed what and when.
- Blocks: Can't debug configuration drift, can't comply with security audit requirements.
- Fix approach: (1) Add audit logging to Settings controller (log before/after for each field). (2) Store in `audit_log` table. (3) Expose via Settings > Audit page.

**No Backup/Restore UI or API:**
- Problem: Backup controller exists (`lib/Purl/API/Controller/Backup.pm`) but no UI to trigger, schedule, or restore backups.
- Blocks: Admins must use ClickHouse native tools manually.
- Fix approach: (1) Add Backup page in settings. (2) Implement schedule-based backups (cron-like). (3) Implement restore endpoint (destructive, require confirmation).

**No Data Retention Policy per Service:**
- Problem: All logs retained uniformly for 30 days. Can't keep verbose DEBUG logs short-term and ERROR logs long-term.
- Blocks: Can't optimize storage for different log types.
- Fix approach: (1) Add retention policy rules by service/level. (2) Store policy in `retention_policies` table. (3) Implement TTL-based deletion.

**No Data Export/Download:**
- Problem: Can only view logs in UI. Can't export to CSV, JSON, or S3 for analysis or compliance.
- Blocks: Can't integrate with external tools (Splunk, Datadog, AWS Athena).
- Fix approach: (1) Add export endpoint with format selector (CSV, JSON, Parquet). (2) Stream large exports to S3 or signed URL. (3) Implement scheduled exports.

---

## Test Coverage Gaps

**Untested Auth Flows:**
- What's not tested: OAuth/OIDC integration (not implemented but designed). SAML attribute mapping edge cases. LDAP fallback to local auth. Multi-factor auth (not implemented).
- Files: `lib/Purl/API/Middleware/Auth.pm`, `lib/Purl/API/Middleware/LDAP.pm`, `lib/Purl/API/Middleware/SAML.pm`
- Risk: Auth middleware changes risk breaking login for federated users.
- Priority: **High** — auth is critical. Add tests for LDAP connection failure, SAML response validation with malformed assertions, token expiry.

**Untested Storage Failover:**
- What's not tested: ClickHouse unavailable during startup. Database connection timeout recovery. Partial query failures (some shards down in cluster mode).
- Files: `lib/Purl/Storage/ClickHouse.pm`
- Risk: Server may crash or hang if ClickHouse is slow/down. No graceful degradation.
- Priority: **High** — affects availability. Add tests for HTTP timeout, connection refused, slow queries. Implement circuit breaker.

**Untested Alert Edge Cases:**
- What's not tested: Alert condition with no matching logs. Alert with regex containing special characters. Alert triggered multiple times in fast succession (deduplication).
- Files: `lib/Purl/Storage/ClickHouse/Alerts.pm`, `lib/Purl/API/Controller/Alerts.pm`
- Risk: Alerts might trigger multiple times, or not at all in edge cases.
- Priority: **Medium** — implement deduplication and edge case tests.

**Untested Frontend State Management:**
- What's not tested: Concurrent store updates (logs refresh while alert dialog open). Store subscription memory leaks. WebSocket disconnect recovery.
- Files: `web/src/stores/`, `web/src/components/`
- Risk: Frontend may crash or leak memory during rapid interactions.
- Priority: **Medium** — add integration tests using Playwright for store interactions.

**Untested Settings Persistence:**
- What's not tested: Config file corruption recovery. Settings change during active queries. Settings reload while WebSocket streaming. Concurrent settings updates from multiple tabs.
- Files: `lib/Purl/Config.pm`, `lib/Purl/API/Controller/Settings.pm`
- Risk: Settings may be partially applied, or server may crash if config corrupted.
- Priority: **Medium** — add file locking, atomic writes, and concurrent update tests.

---

*Concerns audit: 2026-03-10*
