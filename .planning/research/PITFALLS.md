# Pitfalls Research

**Domain:** Perl/Mojolicious + Svelte 5 log aggregation platform — brownfield quality hardening
**Researched:** 2026-03-10
**Confidence:** HIGH (derived from direct codebase analysis in CONCERNS.md + established patterns for this stack)

---

## Critical Pitfalls

### Pitfall 1: Refactoring Breaks the InMemory Mock Contract

**What goes wrong:**
The integration test suite (`t/25_integration_flow.t`) relies on `Purl::Storage::InMemory` — a hand-rolled mock that mirrors the real `Purl::Storage::ClickHouse` interface. When the real storage class is refactored (new methods added, method signatures changed, role responsibilities moved), the mock silently falls out of sync. Tests keep passing against the old mock API, but the real system breaks.

**Why it happens:**
The mock is inline in the test file, not a shared stub. Every time a storage role method is renamed or moved (e.g., extracting `Cache` role methods into a standalone class), the mock is not updated because there is no interface contract enforcing parity. Developers refactor the production code, run tests, see green, and ship.

**How to avoid:**
- Keep the InMemory mock in `t/lib/Purl/Storage/InMemory.pm` (a dedicated file, not inline) so it is easy to audit.
- Add a "method parity test" — a unit test that uses `UNIVERSAL::can` to verify the mock implements every public method of the real storage class.
- When extracting a new role (e.g., `SavedSearches`), immediately update the mock before touching the production code.

**Warning signs:**
- Integration tests pass but manual testing against a real ClickHouse instance fails.
- `grep` for method names used in controllers finds no definition in the mock.
- A new storage method added to a role is called from a controller but missing from `InMemory`.

**Phase to address:** Bug Fix / Refactoring phase — establish mock parity before any storage refactoring begins.

---

### Pitfall 2: Settings Controller Split Leaves Orphaned Routes

**What goes wrong:**
`lib/Purl/API/Controller/Settings.pm` is 1,136 lines handling 10+ unrelated domains. When splitting it into `DatabaseSettings`, `AuthSettings`, etc., routes registered in `Server.pm` must also be updated. If routes are left pointing to the old monolith while the split controllers are added alongside it, both respond and the last registered route wins — silently, with no error.

**Why it happens:**
In `Mojolicious::Lite`, routes are registered imperatively in `Server.pm`. Splitting a controller does not automatically reroute. The developer splits the class, adds the new controller instantiation, but forgets to remove the old Settings routes. The old catch-all continues to match.

**How to avoid:**
- Do the split incrementally: one domain at a time. Move routes for a single settings category (e.g., `clickhouse` settings endpoints) to the new controller, then delete them from the old one. Run `make preflight` after each domain move.
- Write a route inventory test: enumerate all `/api/v1/settings/*` routes before and after the split, verify no route is removed unintentionally.
- The 6 callback dependencies (`rebuild_notifiers`, `rebuild_storage`, `reload_license`, `rebuild_ldap`, `rebuild_saml`, `auth_middleware`) must be threaded into each new controller at construction time — document this dependency list before starting.

**Warning signs:**
- Settings save returns 200 but the underlying callback is not fired (rebuilds don't happen).
- Two controllers both handle the same route path — Mojolicious logs a warning but does not error.
- `make test` passes but live integration shows settings not persisting.

**Phase to address:** Refactoring phase — before any Settings split, establish full route coverage tests.

---

### Pitfall 3: safe_execute Swallows Errors Without CSRF Check

**What goes wrong:**
`Base.pm`'s `safe_execute` wraps every controller action in `eval {}`. CSRF enforcement is supposed to happen inside each POST handler, but because `safe_execute` catches all exceptions silently, a missing CSRF check is invisible during testing (no error is thrown — the request just succeeds). This means CSRF protection appears tested when it is not enforced.

**Why it happens:**
The current `safe_execute` has no pre-hook mechanism. CSRF validation was meant to be added per-endpoint as a manual call (`return $self->render_error(...)`) but this depends on every developer remembering to add it. The eval wrapper means a thrown exception from a half-implemented CSRF check would be eaten, not surfaced.

**How to avoid:**
- Modify `safe_execute` to accept an options hashref: `$self->safe_execute($c, \%opts, sub { ... })` where `%opts` can include `csrf => 1`. This centralizes the check.
- Alternatively, add a before-filter in `Server.pm` that runs CSRF validation for all non-GET routes before the controller is called.
- Write an explicit test: make a POST request to every mutating endpoint without `X-CSRF-Token`, assert 403.

**Warning signs:**
- POST to `/api/v1/alerts` without `X-CSRF-Token` returns 200 (currently confirmed in CONCERNS.md).
- Controller test files that mock the `$c` context never set a CSRF token field, yet tests pass.
- New controllers added during the milestone inherit `Base.pm` but do not call `check_csrf`.

**Phase to address:** Bug Fix phase — fix CSRF enforcement before UI work adds new mutating endpoints.

---

### Pitfall 4: Svelte 5 Store Subscriptions Leak During Component Teardown

**What goes wrong:**
Several large components (`QueryPage.svelte` at 792 lines, `TracesPage.svelte` at 1,161 lines) subscribe to multiple writable stores from `logs.js`, `settings.js`, and `auth.js`. In Svelte 5 runes mode, if a `$effect` or `onDestroy` callback is added incorrectly — or missing entirely — the subscription fires after the component is unmounted. This causes `set` calls on stores from dead components, React-style stale closure bugs, and memory growth on long-running dashboard sessions.

**Why it happens:**
Svelte 4 auto-subscriptions with `$:` labels were self-cleaning. Svelte 5 runes (`$effect`, `$derived`) require explicit cleanup when using imperative subscriptions or `onDestroy`. Large components that were written during a fast iteration phase often mix the two patterns — some stores use auto-subscription syntax, others use `.subscribe()` with a manual unsubscribe that gets dropped during a refactor.

**How to avoid:**
- Audit every `.subscribe()` call in large components (`QueryPage`, `TracesPage`, `Histogram`, `AnalyticsPage`) — each must be paired with an `onDestroy` unsubscribe.
- Prefer `$store` auto-subscription syntax over manual `.subscribe()` for reactive reads.
- For side effects triggered by store changes, use `$effect` in runes mode and verify the return value is a cleanup function when timers or fetch calls are involved.
- Add a memory leak test: mount and unmount `QueryPage` 10 times in a test harness, verify store subscription count does not grow.

**Warning signs:**
- Console errors like "cannot call set on a destroyed component."
- Dashboard memory usage grows over a 30-minute session with no new tabs.
- WebSocket `onmessage` handlers firing after navigating away from a page.

**Phase to address:** UI completion phase — before adding new Svelte components, audit existing subscriptions.

---

### Pitfall 5: Test Mocks Drift From Real ClickHouse Query Signatures

**What goes wrong:**
The `MockCtrl` and `MockStorage` patterns in unit tests (e.g., `t/edge_cases_logs.t`) construct hand-crafted Perl objects. When a storage method's call signature changes (adding a new required parameter like `namespace_id` for multi-tenancy or a `limit` parameter for cardinality capping), the mock does not enforce the new signature. Tests pass, production code fails with "undefined value" or silently wrong results.

**Why it happens:**
Perl does not have a strict interface system. `MockStorage` objects are plain hashrefs with hand-crafted methods — adding a parameter to the real method requires manually updating every test mock that calls it. In a codebase with 25+ controllers each having their own mock patterns, this is easy to miss.

**How to avoid:**
- Consolidate mock implementations into shared fixtures in `t/lib/`. Do not inline mocks in test files.
- Use `Test::MockObject` or `Test::MockModule` so parameter validation can be added once.
- After any storage method signature change, run `grep -r "method_name" t/` to find all mocks calling it.
- For the storage refactoring work, write the new method signature + its mock update in the same commit.

**Warning signs:**
- A test mocks `search_logs` with 3 args but the real method now takes 4.
- `make test` is green but deploying to the demo server shows different behavior.
- New controller tests copy-paste a mock from an old test file without checking if the mock is current.

**Phase to address:** Test coverage phase — standardize mock infrastructure before writing new tests.

---

### Pitfall 6: ClickHouse Synchronous HTTP Blocks Mojolicious Event Loop

**What goes wrong:**
`Purl::Storage::ClickHouse` uses `HTTP::Tiny` synchronously. Mojolicious is an async framework — blocking the worker with a slow ClickHouse query (e.g., cardinality scan over 300GB of data) blocks ALL concurrent requests on that worker process. Under moderate load (5+ simultaneous dashboard users), a single slow query causes cascading request timeouts for all users.

**Why it happens:**
`HTTP::Tiny` with `keep_alive` is easy to use and performs fine at low query volumes. The problem is invisible until multiple users are active simultaneously. Unit tests run in isolation and never simulate concurrent load.

**How to avoid:**
- Add a configurable query timeout at the HTTP::Tiny level: `HTTP::Tiny->new(timeout => 30)`. This prevents indefinite blocking.
- Identify the top 5 slowest query paths (dashboard widgets, field statistics cardinality, pattern detection) and ensure they are cached aggressively — this reduces blocking frequency.
- Do not attempt full async migration in this milestone (high risk, out of scope). The mitigation is timeout + cache, not architecture change.
- Document the known scaling limit: "synchronous ClickHouse queries — add async in a future milestone when concurrency becomes a bottleneck."

**Warning signs:**
- All requests hang simultaneously when one user runs a wide time-range search.
- `top` shows one Perl process at 100% with many others at 0% (blocked).
- Dashboard page load time is 10x slower when 3+ users are active.

**Phase to address:** Production hardening phase — add timeouts and caching before declaring production-ready.

---

### Pitfall 7: Refactoring the Monolith Storage Class Breaks Role Method Resolution

**What goes wrong:**
`Purl::Storage::ClickHouse` consumes 10 Moo roles using `with`. In Perl's Moo/Moose role system, if two roles define a method with the same name, composition fails with a conflict error at compile time. During refactoring — extracting methods from the monolith into new roles — it is easy to accidentally create name conflicts (e.g., a `_execute_query` helper method exists in both `Query` and `Backup` roles).

**Why it happens:**
The original monolith was a single class without roles. Roles were added incrementally and some helper methods were duplicated across them because they were private (underscore prefix). Moo allows role conflicts to be resolved by explicit aliasing, but developers not familiar with Moo role composition may try to add a new role, get a compile-time conflict error, and resolve it incorrectly (e.g., aliasing away the wrong method).

**How to avoid:**
- Before extracting any method into a new role, `grep` across all existing role files for that method name.
- Shared helper methods (e.g., `_execute_query`, `_build_url`) belong in the base class (`ClickHouse.pm`), not in roles. Roles should only contribute public API methods.
- Run `perl -c lib/Purl/Storage/ClickHouse.pm` after every role change — compile-time role conflict errors surface immediately.
- Name private helpers with a role-specific prefix (e.g., `_backup_execute` vs `_query_execute`) to avoid accidental conflicts.

**Warning signs:**
- `make test` fails on `t/03_modules_load.t` with a role composition error.
- `perl -c` on the storage class produces "method conflict in ..." error.
- A helper function called in one role is actually defined in a different role (implicit coupling).

**Phase to address:** Refactoring phase — first task is a role method audit before any extraction.

---

### Pitfall 8: New UI Components Duplicate Business Logic Already in Stores

**What goes wrong:**
When building UI for backend features that currently lack frontend coverage (backup management, audit log, pipeline settings), developers write fetch logic directly inside Svelte components instead of adding it to the appropriate store. The result is the same API call appearing in 3 places: `BackupSettings.svelte`, `DashboardPage.svelte`, and a new `BackupStatus.svelte` widget. When the API endpoint changes, all 3 must be updated.

**Why it happens:**
Svelte's inline `onMount` + `fetch` pattern is so easy that it becomes the default. The existing stores (`logs.js`, `settings.js`, `auth.js`, `dashboard.js`) demonstrate the correct pattern but new components are written by copying the quickest pattern visible in the codebase, not the correct one.

**How to avoid:**
- Before writing any new component, check whether a store for that domain already exists. If it does, add the fetch function there. If not, create the store file first.
- The rule: components only call store functions and bind to store state. They do not contain `fetch()` calls directly.
- New stores follow the existing `logs.js` pattern: writable state stores at the top, async functions below, AbortController for cancellation.
- Code review checkpoint: any new `.svelte` file containing a `fetch(` call that is not delegating to a store function should be rejected.

**Warning signs:**
- A `.svelte` file contains `fetch('/api/v1/backup/...')` directly.
- Two components that deal with the same domain (e.g., backup) make the same API call independently.
- API endpoint rename breaks 3 files instead of 1.

**Phase to address:** UI completion phase — establish the store-first rule before building new components.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Inline mock objects in test files | Fast to write tests | Mocks drift from real interfaces; updating requires touching many files | Never — consolidate into `t/lib/` |
| `safe_execute` with no pre-hooks | Simple API for controllers | Security checks (CSRF, role) forgotten on new endpoints | Never — add CSRF hook to safe_execute |
| Callback injection for Settings side effects | Easy to wire up in Server.pm | 6+ callbacks threaded through every Settings controller split | Acceptable now; replace with event bus in next major milestone |
| Package-level `$storage` and `$broadcaster` in Server.pm | Simple global access | Tests cannot isolate state; parallel test runs share globals | Only acceptable because current test runner is sequential |
| Fixed 1,000-slot latency circular buffer | Pre-allocated, no GC pressure | Fills in 1 second at 1,000 req/sec — metrics page shows only last second of data | Acceptable until concurrent user load demands metrics trending |
| `HTTP::Tiny` synchronous for ClickHouse | Simple, no event loop complexity | Blocks entire worker on slow queries | Acceptable in this milestone; flag for async migration in next |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| ClickHouse HTTP API | Omitting `output_format_json_quote_64bit_integers=1` query param — BigInt IDs truncated silently | Always pass the param; validate in tests that all IDs are returned as strings |
| Session cookie auth | Relying on ephemeral session secret — all sessions invalidated on container restart | Write session secret to `config/server.json` on first startup, read from there on subsequent starts |
| LDAP bind | No connection timeout — one slow LDAP server blocks the auth worker indefinitely | Set `timeout => 5` on Net::LDAP->new(); wrap in alarm() if needed |
| SAML SP key | Storing SP private key in `config/settings.json` — leaked if config volume is readable | Read from `PURL_SAML_SP_KEY` env var only; never write to config |
| Telegram/Slack alerts | Sending alert notifications synchronously in the alert evaluation loop — if webhook is down, evaluation blocks | Evaluate alerts, collect results, then send notifications in a non-blocking step (fire-and-forget or queue) |
| ClickHouse query timeout | No timeout on HTTP::Tiny — slow queries hang workers indefinitely | Set `timeout => 30` on HTTP::Tiny constructor; log slow queries |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Field statistics cardinality scan (`DISTINCT` with no LIMIT) | Field sidebar takes 10+ seconds to load | Add `LIMIT 1000` to all cardinality queries; cache results for 1 hour | 10k+ unique hostnames or service names |
| Per-alert individual ClickHouse queries in evaluation loop | Alert evaluation takes 30+ seconds for 100 alerts | Batch into UNION ALL or consolidated query | 50+ active alert rules |
| Dashboard: 12+ sequential widget queries per page load | Dashboard first paint takes 5+ seconds | Cache widget data for 30 seconds; consolidate queries where possible | 6+ widgets, 3+ concurrent dashboard users |
| In-memory `%metrics` hash accumulating `requests_by_path` keys | Server memory grows over hours | Cap `requests_by_path` keys to top 1,000 paths; discard long-tail paths | Servers with diverse URL patterns, long uptime |
| Pipeline rule regex compiled on every log message | High CPU on ingest at 1,000+ logs/sec | Precompile all rule regexes at startup, cache `qr//` objects | Any production ingest load |
| Auth middleware failed-login hash with no TTL cleanup | Memory leak on long-running servers with many unique IPs | Add periodic cleanup job purging entries older than 1 hour | Servers exposed to internet login scanning |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Default admin password `admin` on first boot | First deployment accessible with known credentials — full compromise | Require `PURL_ADMIN_PASSWORD` env var; fail startup (not just log warning) if unset and no users exist |
| CSRF protection exists but not enforced on all mutable routes | Authenticated users can be tricked into state-changing requests via CSRF | Make CSRF check mandatory in `safe_execute` pre-hook for non-GET; write endpoint coverage test |
| License cache key not including instance ID | Old license info served to new instance after re-activation | Include `instance_id` in cache key; reduce license cache TTL from 1 hour to 5 minutes |
| API keys stored in plain-text `config/settings.json` | Config volume leak exposes all external integrations (Slack, Telegram, webhooks) | Encrypt sensitive fields at rest using a master key from env var; at minimum document the risk clearly |
| Broadcast Redis fallback is silent | Multi-replica deployments lose real-time sync with no error — users see stale data | Log clearly which broadcast mode is active at startup; in cluster mode, fail startup if Redis is required but unavailable |
| LDAP bind password written to config file | LDAP bind password in config = full directory read access if leaked | Read `PURL_LDAP_BIND_PASSWORD` from env var only; never persist to config |

---

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Settings save with no optimistic feedback | User clicks Save, nothing visible happens for 2 seconds — clicks again, double-save | Show spinner immediately on click; disable button during request; show success/error toast |
| Backup/restore UI triggering destructive operations without confirmation | Accidental data loss | Require confirmation dialog with explicit text ("type RESTORE to confirm") for destructive actions |
| Alert test notification with no status feedback | User triggers test alert, does not know if Telegram/Slack message was sent | Return delivery status from backend test endpoint; show "Sent" or "Failed: [reason]" in UI |
| Long log search results with no pagination state in URL | Refresh loses query and time range — user must re-enter | Persist query, time range, and page to URL query params via `history.replaceState` |
| Settings categories all rendering simultaneously | Settings page slow first load — all sections fetch their own data | Lazy-load settings sections on tab selection; do not mount inactive sections |
| Error messages from backend exposed directly in UI | ClickHouse SQL errors shown to end users ("DB::Exception: ...") | Sanitize backend errors in `render_error` — log full error, return generic message to client |

---

## "Looks Done But Isn't" Checklist

- [ ] **CSRF protection:** Middleware exists and `check_csrf` is implemented — verify every POST/PUT/DELETE endpoint actually calls it (not just relies on middleware that can be bypassed)
- [ ] **Auth role checks:** `require_role` exists in `Base.pm` — verify new Settings controllers all call it on admin-only endpoints
- [ ] **Settings split:** New settings controllers instantiated in `Server.pm` with all required callbacks — verify each callback fires correctly via integration test
- [ ] **Storage role extraction:** New roles compile without method conflicts — verify `perl -c lib/Purl/Storage/ClickHouse.pm` passes after each extraction
- [ ] **Svelte store subscriptions:** New components that subscribe to stores — verify each subscription is cleaned up in `onDestroy` or uses auto-subscription syntax
- [ ] **Test mocks updated:** After any storage method signature change — verify mock in `t/25_integration_flow.t` is updated to match
- [ ] **WebSocket live tail:** Shows as "working" because connection establishes — verify it handles reconnect after 30-second backend idle timeout (Mojolicious default)
- [ ] **License feature gating:** `require_feature` returns 0 and renders 403 — verify the calling controller also `return`s after the call (does not continue executing)
- [ ] **Rate limiting on ingest:** Config flag present — verify it is actually checked on the `POST /api/v1/logs` route, not just enabled in middleware
- [ ] **ClickHouse query timeout:** HTTP::Tiny has `keep_alive` set — verify `timeout` is also set to a bounded value (default is no timeout)

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Mock drift causes production regression | MEDIUM | Bisect git history to find when mock and real diverged; add parity test; fix mock; add regression test for the specific broken path |
| Settings split leaves orphaned routes | MEDIUM | Add route inventory test; check Mojolicious route table via `$app->routes->to_string`; restore missing routes |
| CSRF enforcement gap exploited | HIGH | Audit all non-GET routes immediately; add CSRF check to safe_execute pre-hook; rotate any API keys that may have been forged; add penetration test |
| Moo role composition conflict breaks startup | LOW | `perl -c` pinpoints the conflict immediately; rename the conflicting private method in the newer role; rerun `make test` |
| Svelte store subscription leak causes memory growth | MEDIUM | Use Chrome DevTools memory profiler to identify leaking subscriptions; add cleanup to identified components; add automated memory growth test |
| ClickHouse query blocks all workers | MEDIUM | Add `timeout => 30` to HTTP::Tiny immediately; identify the slow query path from logs; add caching or query limit |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| InMemory mock drift | Bug Fix / Refactoring — before storage changes | Add `t/lib/Purl/Storage/InMemory.pm` parity test; run it as part of `make test` |
| Settings split orphaned routes | Refactoring — incremental domain-by-domain split | Route inventory test before and after each split step |
| CSRF not enforced | Bug Fix — first priority | Automated test: POST to every mutating endpoint without token, assert 403 |
| Svelte subscription leaks | UI completion — before new components are built | Audit existing large components; add `onDestroy` cleanup where missing |
| Test mock signature drift | Test coverage — consolidate mocks first | Move mocks to `t/lib/`; add compilation test that loads all mocks |
| Synchronous ClickHouse blocking | Production hardening | Add `timeout` to HTTP::Tiny; verify via slow-query simulation test |
| Moo role composition conflicts | Refactoring — role method audit first step | `perl -c` check in `make lint-perl` |
| UI duplicating store logic | UI completion — store-first rule enforced | Code review: no `fetch()` directly in `.svelte` files |

---

## Sources

- Direct codebase analysis: `lib/Purl/API/Controller/Settings.pm` (1,136 lines), `lib/Purl/Storage/ClickHouse.pm` (1,316 lines, 10 roles)
- `.planning/codebase/CONCERNS.md` — project's own tech debt and bug audit (2026-03-10)
- `t/25_integration_flow.t` — inline InMemory mock pattern observed directly
- `t/edge_cases_logs.t` — MockCtrl/MockStorage pattern observed directly
- `lib/Purl/API/Controller/Base.pm` — `safe_execute` implementation reviewed
- `lib/Purl/API/Server.pm` — package-level globals, metrics buffer, broadcast setup reviewed
- `web/src/stores/` — Svelte store patterns observed across `logs.js`, `auth.js`
- Moo role composition behavior: established Perl community knowledge (HIGH confidence)
- Mojolicious::Lite route ordering behavior: established framework knowledge (HIGH confidence)
- Svelte 5 `$effect` cleanup requirement: documented in Svelte 5 migration guide (HIGH confidence)

---
*Pitfalls research for: Perl/Mojolicious + Svelte 5 log aggregation platform — quality hardening milestone*
*Researched: 2026-03-10*
