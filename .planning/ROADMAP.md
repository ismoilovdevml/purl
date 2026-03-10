# Roadmap: Purl — Quality & Completeness Milestone

## Overview

This milestone hardens the existing Purl codebase into production-ready state without adding new features. The work proceeds in strict dependency order: security baseline first (CSRF enforcement makes test signals reliable), then structural refactoring (splits the god-class Settings controller so its logic can actually be tested), then test coverage expansion (fills the 9 uncovered controllers and edge cases), then UI completion (wires backend capabilities that operators cannot currently see), and finally frontend unit test infrastructure. Each phase delivers a coherent, verifiable capability that unblocks the next.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Security & Infrastructure Baseline** - CSRF enforcement, consolidated mock, typed exceptions
- [ ] **Phase 2: God Class Refactoring** - Settings.pm split, RateLimit extraction, Validation module
- [ ] **Phase 3: Test Coverage Expansion** - 9 missing controller tests, failover, edge cases, Devel::Cover
- [ ] **Phase 4: UI Completion** - Wire all backend features that have no frontend coverage
- [ ] **Phase 5: Frontend Testing** - Vitest setup, store unit tests, Playwright CI fix

## Phase Details

### Phase 1: Security & Infrastructure Baseline
**Goal**: Every mutating endpoint is protected by CSRF enforcement, the InMemory storage mock is a first-class module with parity guarantees, and typed exceptions replace bare die strings in safe_execute
**Depends on**: Nothing (first phase)
**Requirements**: SEC-01, SEC-02, SEC-03, SEC-04
**Success Criteria** (what must be TRUE):
  1. A POST to any mutating endpoint without a CSRF token returns 403 (verifiable by running the automated CSRF test suite)
  2. The InMemory storage mock lives in t/lib/Purl/Storage/InMemory.pm and a parity test asserts every public storage method is implemented
  3. safe_execute raises Purl::Error::NotFound and Purl::Error::Validation typed exceptions instead of bare die strings
  4. make preflight passes with all four SEC requirements delivered
**Plans**: TBD

### Phase 2: God Class Refactoring
**Goal**: Controller::Settings is split into four focused domain controllers, RateLimit is a standalone middleware module, and Purl::Validation is an independently testable module — all without breaking existing API contracts
**Depends on**: Phase 1
**Requirements**: REF-01, REF-02, REF-03, REF-04, REF-05
**Success Criteria** (what must be TRUE):
  1. Settings endpoints (database, notifications, auth, integrations) respond correctly from their new controllers — existing API paths return identical payloads
  2. A route inventory test passes, confirming every registered route maps to an existing controller action
  3. RateLimit behavior (429 after threshold, X-RateLimit-Remaining header) is unchanged and rate limiter lives in Middleware::RateLimit
  4. Purl::Validation can be loaded and invoked standalone without importing ClickHouse storage roles
  5. make preflight passes with no regressions to existing test suite
**Plans**: TBD

### Phase 3: Test Coverage Expansion
**Goal**: Every controller has at least one test file, storage failover and edge cases are covered, alert deduplication is tested, and Devel::Cover produces a baseline coverage report
**Depends on**: Phase 2
**Requirements**: TST-01, TST-02, TST-03, TST-04, TST-05, TST-06, TST-07, TST-08, TST-09, TST-10, TST-11, TST-12
**Success Criteria** (what must be TRUE):
  1. prove -r t/ runs test files for Pipeline, Dashboard, Config, AI, ESCompat, OTLP, and Syslog controllers with no failures
  2. K8sAudit and K8sHealth tests cover the depth-verification scenarios identified in the research (expanded beyond current minimal coverage)
  3. A storage failover test confirms the system returns an appropriate error response when ClickHouse is unavailable at startup
  4. Alert edge case tests cover deduplication, regex with special characters, and zero-match conditions without false positives
  5. Devel::Cover produces a coverage report that establishes a measurable baseline (line/branch/condition percentages documented)
**Plans**: TBD

### Phase 4: UI Completion
**Goal**: Every backend capability is reachable through the dashboard UI — notifier status, circuit breaker state, pipeline dry-run, cache-clear, ingest sources, audit export, K8s audit stream, and alert last-fired are all visible and functional
**Depends on**: Phase 3
**Requirements**: UI-01, UI-02, UI-03, UI-04, UI-05, UI-06, UI-07, UI-08
**Success Criteria** (what must be TRUE):
  1. NotificationSettings shows a live status panel indicating which of Telegram, Slack, and Webhook channels are configured and reachable (data from /api/analytics/notifiers)
  2. AboutSettings displays the current circuit breaker state from the /api/health response
  3. PipelineSettings dry-run button sends a real request to the test endpoint and displays the result in the modal
  4. Admin UI cache-clear button calls /api/config/clear-cache and shows confirmation to the operator
  5. Ingest sources panel shows last-received timestamp and log count for OTLP, Syslog, K8s audit, and HTTP protocols
  6. Audit log export produces a downloadable CSV or JSON file from AuditSettings
  7. K8sPage shows the K8s audit event stream alongside the existing PodStatusPanel
  8. AlertsPanel displays the last evaluation result (last-fired timestamp) per alert rule
**Plans**: TBD

### Phase 5: Frontend Testing
**Goal**: Frontend unit test infrastructure is operational, critical stores are covered by unit tests, and Playwright can run against a local server in CI
**Depends on**: Phase 4
**Requirements**: FE-01, FE-02, FE-03
**Success Criteria** (what must be TRUE):
  1. npx vitest run executes store and component unit tests against the Svelte 5 codebase without configuration errors
  2. Unit tests for auth.js, logs.js, license.js, and settings.js stores pass, covering the critical state transitions each store manages
  3. Playwright tests run against a localhost target (PLAYWRIGHT_BASE_URL env var) and pass in a CI environment without referencing the hardcoded production IP
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Security & Infrastructure Baseline | 0/TBD | Not started | - |
| 2. God Class Refactoring | 0/TBD | Not started | - |
| 3. Test Coverage Expansion | 0/TBD | Not started | - |
| 4. UI Completion | 0/TBD | Not started | - |
| 5. Frontend Testing | 0/TBD | Not started | - |
