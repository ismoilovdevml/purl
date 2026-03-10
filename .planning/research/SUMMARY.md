# Project Research Summary

**Project:** Purl — Self-hosted Log Aggregation Platform
**Domain:** Brownfield quality hardening — Perl/Mojolicious + Svelte 5
**Researched:** 2026-03-10
**Confidence:** HIGH (all research derived from direct codebase analysis)

## Executive Summary

Purl is a production-capable self-hosted log aggregation platform built on Perl 5.40/Mojolicious, Svelte 5, and ClickHouse. The current codebase has a functioning feature surface (25 controllers, 40+ UI components, 40 test files) but suffers from structural debt in three specific areas: a 1,121-line god-class Settings controller, package-level singletons in Server.pm that prevent proper test isolation, and no mechanism enforcing CSRF protection across all mutating endpoints. The hardening milestone's goal is not new features — it is to make the existing platform production-worthy through targeted refactoring, test coverage expansion, and completing the backend-to-UI wiring gaps that leave some features invisible to users.

The recommended approach follows a strict dependency-ordered sequence: fix the security baseline (CSRF), establish proper mock infrastructure, then split the god classes, then expand test coverage, then complete UI gaps. Attempting to add test coverage before the mock infrastructure is consolidated results in duplicate, drift-prone mocks that give false confidence. Attempting to split Settings.pm before extracting shared helpers creates duplication. The research is unanimous on this sequencing: correctness before coverage, structure before surface area.

The primary risks are scope creep (the anti-features list is explicit: no new delivery channels, no log export, no multi-tenancy) and mock drift during refactoring (the InMemory storage mock will fall out of sync with the real interface unless parity enforcement is built in as a prerequisite). Secondary risk is the synchronous ClickHouse HTTP blocking the Mojolicious event loop under concurrent load — mitigated in this milestone by adding timeouts and caching, not by async migration.

## Key Findings

### Recommended Stack

The core stack is unchanged and appropriate for this milestone. The hardening work adds testing infrastructure that was identified as absent during research. On the Perl side: `Test::Deep` for structured JSON response assertions, `Test::Exception` for explicit exception-path testing, `Test::MockModule` for surgical method overrides, and `Devel::Cover` for coverage measurement. On the frontend: `vitest 3.x` + `@testing-library/svelte 5.x` for Svelte component and store unit tests, `@vitest/coverage-v8` for JS coverage. Playwright's remote-IP hardcode must be fixed to allow CI-local E2E tests.

No existing stack element should be replaced. The Perl testing additions are additive to the existing `Test::More`/`Test::Mojo`/`prove` setup. Vitest is additive to the existing Playwright E2E coverage.

**Core technologies:**
- `Test::Deep` / `Test::Exception`: explicit JSON shape and exception assertions — replaces fragile `eval { }; ok($@)` patterns
- `Devel::Cover`: Perl line/branch/condition coverage — no coverage measurement currently exists for 25+ controllers
- `vitest 3.x` + `@testing-library/svelte 5.x`: Svelte component unit testing — zero frontend unit tests currently exist (Playwright only covers remote E2E)
- `@vitest/coverage-v8`: JS coverage reporting — pairs with vitest, zero config overhead

**Critical version constraint:** `@testing-library/svelte` must be v5.x — v4 does not support Svelte 5 runes.

### Expected Features

This is a hardening milestone. The feature research re-frames the question: "which backend capabilities have no UI, and which tests are missing?" New functionality is explicitly out of scope.

**Must have (production-ready baseline — P1):**
- CSRF enforcement in `Base.pm safe_execute` — security gap confirmed in CONCERNS.md; all POST/PUT/DELETE currently unprotected
- `Settings.pm` split into 4 sub-controllers — blocks testability of settings endpoints; 1,121-line god class
- Test files for 9 controllers with no coverage: Pipeline, Dashboard, Config, AI, ESCompat, OTLP, Syslog (plus K8sAudit/K8sHealth depth verification)
- Storage failover tests — no test for ClickHouse unavailable at startup
- Wire `/api/analytics/notifiers` to NotificationSettings — backend exists, UI does not consume it
- Wire `circuit_breaker` state to AboutSettings — backend returns it, UI does not display it
- Pipeline dry-run wired in PipelineSettings — `showTestModal` state exists, fetch call not wired
- Cache-clear button in admin UI — endpoint exists, no UI button

**Should have (v1.x, after core hardening — P2):**
- Ingest sources status panel (OTLP, Syslog, K8s audit last-received)
- Audit log export (CSV download button)
- K8s audit event stream wired in K8sPage
- Alert last-fired display in AlertsPanel

**Defer (v2+):**
- Alert history table with ClickHouse schema
- Pattern trend sparklines
- Per-service data retention rules
- Log export to CSV/S3
- New alert delivery channels (PagerDuty, OpsGenie)

### Architecture Approach

The architecture is sound at the macro level (middleware pipeline, thin controllers over storage roles, Svelte store-as-source-of-truth) but has three god-class violations and a package-singleton anti-pattern in Server.pm. The refactoring target is surgical: split `Controller::Settings` into four domain-focused sub-controllers, extract `RateLimit` from `Middleware::Auth`, extract `Purl::Validation` from the storage role, and move package globals in Server.pm toward instance attributes. The frontend requires extracting an `api/` layer from stores and a `Router.svelte` from `App.svelte`, but these are lower priority than backend corrections.

**Major components and required changes:**
1. `Controller::Settings` — split into `Database`, `Notifications`, `Auth`, `Integrations` sub-controllers; extract `Settings::Base` helpers first
2. `Purl::Validation` — extract from `Storage::ClickHouse::Query` role; enables standalone unit testing of field validation
3. `Middleware::Auth` — extract `RateLimit` as standalone class with cleanup job; fixes in-memory state leak
4. `Controller::Base::safe_execute` — add typed exception handling (`Purl::Error::NotFound`, `Purl::Error::Validation`) and CSRF pre-hook
5. `Purl::Storage::InMemory` — move from inline test code to `lib/` with method parity test
6. `Server.pm` — package globals must become instance attributes for proper test injection

### Critical Pitfalls

1. **InMemory mock drift** — When storage roles are refactored, the inline `t/25_integration_flow.t` mock silently falls out of sync. Fix: move mock to `t/lib/Purl/Storage/InMemory.pm` and add a parity test that uses `UNIVERSAL::can` to verify every public storage method is implemented in the mock. Do this before any storage refactoring.

2. **Settings split leaves orphaned routes** — Splitting `Settings.pm` while leaving old routes registered in `Server.pm` causes silent double-handling (last registered route wins). Fix: split one domain at a time, remove old routes immediately, run `make preflight` after each domain. Write a route inventory test before starting.

3. **CSRF not enforced despite check_csrf existing** — `safe_execute` has no pre-hook; CSRF enforcement depends on every developer remembering to call it per endpoint. Currently confirmed missing on POST endpoints. Fix: add CSRF as a `safe_execute` option or Mojolicious before-filter; write an automated test that POSTs to every mutating endpoint without a token and asserts 403.

4. **Svelte 5 store subscription leaks** — Large components (`QueryPage.svelte` at 792 lines, `TracesPage.svelte` at 1,161 lines) mix Svelte 4 auto-subscription and manual `.subscribe()` patterns. Missing `onDestroy` cleanup causes memory growth on long dashboard sessions. Fix: audit all `.subscribe()` calls before building new components; enforce `$store` auto-subscription syntax for reactive reads.

5. **Moo role composition conflicts** — Extracting methods into new storage roles risks name conflicts on private helpers (e.g., `_execute_query` defined in multiple roles). Fix: grep for method names before extraction; run `perl -c lib/Purl/Storage/ClickHouse.pm` after every role change; add to `make lint-perl` CI check.

## Implications for Roadmap

Based on research, suggested 5-phase structure:

### Phase 1: Security and Infrastructure Baseline
**Rationale:** CSRF enforcement is a prerequisite for all subsequent test work — tests without CSRF enforcement pass for the wrong reason, making coverage numbers misleading. The InMemory mock must be consolidated before any storage refactoring or test expansion touches it.
**Delivers:** Security baseline (CSRF enforced on all mutating endpoints), consolidated mock infrastructure in `t/lib/`, typed exception classes in `Base.pm`
**Addresses:** FEATURES.md P1 items — CSRF enforcement, `Base.pm safe_execute` CSRF pre-hook
**Avoids:** PITFALLS.md Pitfall 3 (CSRF swallowed by safe_execute), Pitfall 1 (mock drift before storage work begins), Pitfall 5 (test mock signature drift)

### Phase 2: God Class Refactoring
**Rationale:** Settings.pm split is a testability prerequisite — without it, settings endpoints can only be tested via full integration overhead. RateLimit extraction fixes the in-memory leak. Validation extraction enables standalone unit testing. These refactors have no user-visible impact but unlock all subsequent test work.
**Delivers:** `Controller::Settings` split into 4 domain controllers, `Middleware::RateLimit` extracted, `Purl::Validation` module, route inventory test coverage
**Addresses:** FEATURES.md P1 — Settings testability blocker; ARCHITECTURE.md — boundary violations
**Avoids:** PITFALLS.md Pitfall 2 (orphaned routes during split), Pitfall 7 (Moo role conflicts during extraction)

### Phase 3: Test Coverage Expansion
**Rationale:** With CSRF enforced and mocks consolidated, test coverage can be meaningfully expanded. Controllers that had no test file now have a working foundation to build against. Storage failover tests become possible once the InMemory mock is a real module.
**Delivers:** Test files for 9 uncovered controllers, storage failover tests, alert edge case tests, settings persistence tests, `Devel::Cover` baseline measurement
**Addresses:** FEATURES.md P1 — test coverage gap map (Pipeline, Dashboard, Config, AI, ESCompat, OTLP, Syslog); STACK.md — Devel::Cover integration
**Avoids:** PITFALLS.md Pitfall 5 (mock signatures standardized before test expansion)

### Phase 4: UI Completion
**Rationale:** Backend capabilities that have no UI are invisible to operators. The three lowest-effort, highest-value wiring tasks (notifier status, circuit breaker state, pipeline dry-run) should be completed first. Store-first discipline must be enforced before building new Svelte components.
**Delivers:** NotificationSettings notifier status panel, AboutSettings circuit breaker display, PipelineSettings dry-run wired, cache-clear button; then ingest sources panel, audit export, K8s audit stream, alert last-fired
**Addresses:** FEATURES.md P1/P2 UI gaps — all "PARTIAL" and "NONE" UI coverage items from the controller table
**Avoids:** PITFALLS.md Pitfall 4 (Svelte subscription leak audit before new components), Pitfall 8 (store-first rule — no fetch() in .svelte files)

### Phase 5: Frontend Unit Testing and Production Hardening
**Rationale:** With backend stable and UI complete, frontend unit test infrastructure can be added without distraction. ClickHouse timeout enforcement and caching improvements protect the single-server deployment from slow-query blocking.
**Delivers:** Vitest + @testing-library/svelte setup, store unit tests, component tests for critical UI, HTTP::Tiny timeout enforcement, Playwright baseURL env-var fix, `Devel::Cover` coverage report with targets
**Addresses:** STACK.md — vitest/testing-library installation; PITFALLS.md Pitfall 6 (synchronous ClickHouse blocking)
**Avoids:** Scope creep into v2+ features (alert history schema, pattern sparklines)

### Phase Ordering Rationale

- Security before testing: CSRF gap makes test pass/fail signals unreliable. Fix the signal before expanding coverage.
- Mock consolidation before storage refactoring: The InMemory mock is the integration test foundation. Making it a proper module with parity enforcement prevents test-passing regressions during Phase 2 refactoring.
- Refactoring before coverage: Writing tests against a 1,121-line god class produces tests that are hard to maintain and provide no guidance on what unit to test. Split first, test the resulting units.
- UI completion after backend stability: Adding new Svelte components before store subscription leaks are audited embeds new leaks.
- Frontend testing last: Vitest setup is a tooling concern that should not block backend hardening progress.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2 (Settings split):** The 6 callback dependencies (`rebuild_notifiers`, `rebuild_storage`, `reload_license`, `rebuild_ldap`, `rebuild_saml`, `auth_middleware`) must be fully mapped before splitting begins. A dependency graph session reading Server.pm carefully is recommended.
- **Phase 3 (Storage failover tests):** The ClickHouse mock needs HTTP-layer simulation (not just method stubbing) to test connection failure at startup. The exact mechanism for injecting failure into HTTP::Tiny needs a research pass.

Phases with standard patterns (skip research-phase):
- **Phase 1 (CSRF + mock consolidation):** Patterns are fully documented in CONCERNS.md and PITFALLS.md. Implementation is mechanical.
- **Phase 4 (UI wiring):** All target endpoints exist and return the right data. This is plumbing work with well-documented Svelte patterns.
- **Phase 5 (vitest setup):** STACK.md contains the complete config. Standard Svelte 5 community patterns apply.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM | Core stack HIGH confidence (direct codebase); testing library versions MEDIUM — verify on MetaCPAN/npmjs before pinning; external search tools unavailable during research |
| Features | HIGH | Derived from direct controller and UI component analysis; gap map is authoritative |
| Architecture | HIGH | Direct code inspection of Server.pm, Settings.pm, ClickHouse.pm, Controller::Base; component boundaries and violations confirmed |
| Pitfalls | HIGH | Derived from CONCERNS.md (project's own bug audit) + direct code inspection of known issues |

**Overall confidence:** HIGH

### Gaps to Address

- **@testing-library/svelte v5 Svelte 5 runes compatibility:** STACK.md flags this as needing verification before install. Confirm v5 changelog supports runes-mode components before adding to package.json.
- **Alert history decision:** FEATURES.md identifies alert history as requiring a schema decision (in-memory last-N vs ClickHouse table). This is deferred to v2+ but the decision affects the Phase 4 UI work scope for AlertsPanel.
- **Server.pm package globals migration scope:** The research recommends moving package globals to instance attributes for proper DI, but flags this as Phase 3 infrastructure work. Verify whether this is strictly required for the Phase 3 test expansion goals or can be deferred further.
- **Async ClickHouse HTTP:** Synchronous HTTP::Tiny is acknowledged as the primary scaling bottleneck. The mitigation (timeout + cache) is adequate for this milestone. Document explicitly as a known constraint for the next feature milestone.

## Sources

### Primary (HIGH confidence)
- Direct codebase analysis: `lib/Purl/API/Controller/` (25 controllers), `web/src/components/` (40+ components), `t/` (40 test files, 9,945 lines) — 2026-03-10
- `.planning/codebase/CONCERNS.md` — project's own tech debt and confirmed bug audit
- `.planning/codebase/TESTING.md` — test framework patterns and identified gaps
- `.planning/codebase/ARCHITECTURE.md` — system structure documentation
- `.planning/PROJECT.md` — milestone scope and constraints

### Secondary (MEDIUM confidence)
- Training knowledge (through August 2025) for Perl CPAN module recommendations — Test::Deep, Test::Exception, Test::MockModule, Devel::Cover versions
- Training knowledge for Vitest 3.x + @testing-library/svelte 5.x Svelte 5 runes compatibility

### Tertiary (LOW confidence)
- External search tools (WebSearch, WebFetch, Bash) were unavailable during research sessions. All external version claims should be verified on MetaCPAN and npmjs.com before pinning in cpanfile/package.json.

---
*Research completed: 2026-03-10*
*Ready for roadmap: yes*
