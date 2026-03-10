# Architecture Research

**Domain:** Self-hosted log aggregation platform (Mojolicious + Svelte 5)
**Researched:** 2026-03-10
**Confidence:** HIGH — based on direct codebase analysis

## Standard Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        FRONTEND (Svelte 5 SPA)                          │
├────────────────────────────────────────────────────────────────────────┤
│  ┌────────────┐  ┌────────────┐  ┌─────────────┐  ┌──────────────────┐ │
│  │ Page       │  │ Settings   │  │ UI          │  │ Feature-specific │ │
│  │ Components │  │ Components │  │ Primitives  │  │ Components       │ │
│  └─────┬──────┘  └─────┬──────┘  └──────┬──────┘  └────────┬─────────┘ │
│        │               │                │                   │           │
│  ┌─────┴───────────────┴────────────────┴───────────────────┴─────────┐ │
│  │              Svelte Stores (logs, auth, license, settings…)        │ │
│  └──────────────────────────────┬──────────────────────────────────────┘ │
└─────────────────────────────────┼───────────────────────────────────────┘
                                  │ HTTP / WebSocket
┌─────────────────────────────────┼───────────────────────────────────────┐
│                     BACKEND (Mojolicious::Lite)                         │
├─────────────────────────────────┼───────────────────────────────────────┤
│  ┌──────────────────────────────┴──────────────────────────────────────┐ │
│  │          Middleware Pipeline (Auth → License → NamespaceScope)      │ │
│  └──────────────────────────────┬──────────────────────────────────────┘ │
│                                 │                                        │
│  ┌─────────┐ ┌─────────┐ ┌─────┴────┐ ┌──────────┐ ┌────────────────┐  │
│  │ Logs    │ │ Alerts  │ │ Settings │ │ Auth     │ │ 21 other       │  │
│  │ Ctrl    │ │ Ctrl    │ │ Ctrl     │ │ Ctrl     │ │ Controllers    │  │
│  └────┬────┘ └────┬────┘ └────┬─────┘ └────┬─────┘ └───────┬────────┘  │
│       │           │           │             │               │            │
│  ┌────┴───────────┴───────────┴─────────────┴───────────────┴──────────┐ │
│  │                  Controller Base (safe_execute, cache, RBAC)        │ │
│  └──────────────────────────────┬──────────────────────────────────────┘ │
│                                 │                                        │
│  ┌──────────────────────────────┴──────────────────────────────────────┐ │
│  │               Purl::Storage::ClickHouse (+ 11 Moo roles)           │ │
│  └──────────────────────────────┬──────────────────────────────────────┘ │
└─────────────────────────────────┼───────────────────────────────────────┘
                                  │ HTTP API
┌─────────────────────────────────┼───────────────────────────────────────┐
│                         ClickHouse + Config Files                       │
│  ┌──────────────────┐  ┌────────┴──────┐  ┌────────────────────────┐   │
│  │ logs (MergeTree) │  │ settings.json │  │ S3 (backups)           │   │
│  └──────────────────┘  └───────────────┘  └────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Current Status |
|-----------|----------------|----------------|
| `Server.pm` | App bootstrap, route registration, package-level state | Overcrowded — 400+ lines, package globals, `Mojolicious::Lite` |
| `Controller::Base` | safe_execute, cache, render_error, require_feature, RBAC | Well-structured, clean |
| `Controller::Settings` | ALL settings CRUD (DB, auth, LDAP, SAML, Slack, Telegram, etc.) | Violation — 1,121 lines, multiple unrelated domains |
| `Storage::ClickHouse` | ClickHouse connection + 11 Moo roles consumed | Role composition is good; main class mixes concerns |
| `Storage::ClickHouse::Query` | SQL builder, field validation, search, histogram | Contains validation logic that belongs elsewhere |
| `Middleware::Auth` | API key + session auth, CSRF, rate limiting, failed login tracking | In-memory state leaks; three responsibilities in one class |
| `Middleware::License` | JWT RS256 decode, feature gates, plan detection | Clean but cache key bug |
| `Alert::*` | Telegram/Slack/Webhook delivery | Well-structured, abstract base + impls |
| `Broadcast::*` | WebSocket fan-out (local or Redis) | Silent fallback is dangerous |
| `Svelte stores` | All API calls, reactive state | Stores conflate fetching + state (no separation of data-access layer) |
| `App.svelte` | Root component + routing + page state + mobile menu | Too much responsibility; needs page router |

## Recommended Project Structure

### Backend — Target State After Refactoring

```
lib/Purl/
├── API/
│   ├── Server.pm                     # App factory only — no package globals
│   ├── Router.pm                     # Route definitions extracted from Server.pm
│   ├── Controller/
│   │   ├── Base.pm                   # (keep as-is, clean)
│   │   ├── Logs.pm                   # (keep, minor improvements)
│   │   ├── Auth.pm                   # (keep)
│   │   ├── Alerts.pm                 # (keep)
│   │   ├── Settings/
│   │   │   ├── Database.pm           # ClickHouse config (split from Settings.pm)
│   │   │   ├── Notifications.pm      # Slack/Telegram/Webhook (split)
│   │   │   ├── Auth.pm               # Users, passwords, LDAP, SAML (split)
│   │   │   ├── Integrations.pm       # Redis, K8s, external (split)
│   │   │   └── Base.pm               # Shared settings helpers
│   │   └── ... (25 other controllers, unchanged)
│   └── Middleware/
│       ├── Auth.pm                   # Auth only — extract rate limiting
│       ├── RateLimit.pm              # Extracted rate limit logic
│       ├── License.pm                # (keep, fix cache key bug)
│       ├── LDAP.pm                   # (keep, add connection pool)
│       ├── SAML.pm                   # (keep)
│       └── NamespaceScope.pm         # (keep)
├── Storage/
│   ├── ClickHouse.pm                 # Connection + role composition only
│   └── ClickHouse/
│       ├── Query.pm                  # (keep, extract validation)
│       ├── Alerts.pm                 # (keep, add batch evaluation)
│       ├── Cache.pm                  # (keep)
│       ├── Dashboard.pm              # (keep)
│       └── ... (8 other roles, unchanged)
├── Validation.pm                     # NEW: extracted from Query.pm roles
├── Alert/
│   ├── Base.pm                       # (keep)
│   ├── Telegram.pm                   # (keep)
│   ├── Slack.pm                      # (keep)
│   └── Webhook.pm                    # (keep)
├── Broadcast/
│   ├── Local.pm                      # (keep, fix race condition)
│   └── Redis.pm                      # (keep, enforce required in cluster mode)
├── Config.pm                         # (keep, add atomic write + file locking)
├── Pipeline/Engine.pm                # (keep, add regex precompilation)
└── Util/Time.pm                      # (keep)
```

### Frontend — Target State After Refactoring

```
web/src/
├── App.svelte                        # Root mount + auth check only (strip routing)
├── Router.svelte                     # NEW: extracted page routing
├── pages/                            # NEW: top-level page components (renamed from root)
│   ├── LogsPage.svelte               # Current logs section in App.svelte
│   ├── AnalyticsPage.svelte          # (move from components/)
│   ├── TracesPage.svelte             # (move from components/)
│   ├── K8sPage.svelte                # (move from components/)
│   └── QueryPage.svelte              # (move from components/)
├── components/
│   ├── log/                          # (keep as-is)
│   ├── settings/                     # (keep as-is)
│   ├── dashboard/                    # (keep as-is)
│   ├── ai/                           # (keep as-is)
│   ├── alerts/                       # (keep as-is)
│   ├── k8s/                          # (keep as-is)
│   └── ui/                           # (keep as-is)
├── stores/
│   ├── logs.js                       # (keep, extract API calls to api/)
│   ├── auth.js                       # (keep)
│   ├── license.js                    # (keep)
│   ├── settings.js                   # (keep)
│   ├── dashboard.js                  # (keep)
│   ├── toast.js                      # (keep)
│   └── cluster.js                    # (keep)
├── api/                              # NEW: extracted fetch calls from stores
│   ├── logs.js                       # fetch wrappers for /api/logs
│   ├── auth.js                       # fetch wrappers for /api/auth
│   └── settings.js                   # fetch wrappers for /api/settings
└── utils/
    ├── format.js                     # (keep)
    ├── colors.js                     # (keep)
    └── dom.js                        # (keep)
```

### Structure Rationale

- **Settings split (4 controllers):** Reduces 1,121-line god class to ~250-line focused controllers. Each handles its own validation, persistence, and callback triggering. Reduces regression risk when modifying LDAP config.
- **Validation.pm extraction:** `_validate_field`, `_validate_level`, `_sanitize_identifier` currently live inside a storage role. Moving to a standalone module makes unit testing trivial and prevents duplication across future modules.
- **Router.pm extraction:** Server.pm currently handles both app initialization AND all 80+ route definitions. Extracting routes into `Router.pm` means Server.pm becomes an app factory — this is the standard Mojolicious full-app pattern.
- **api/ layer in frontend:** Stores currently contain raw `fetch()` calls mixed with state management. Extracting API calls into an `api/` module means stores become pure state, and API behavior can be tested in isolation.
- **pages/ directory:** `App.svelte` currently manages routing, mobile menu, error state, interval timers, and data fetching for the main view — too many responsibilities. Extracting a Router and page components isolates concerns.

## Architectural Patterns

### Pattern 1: Controller Thin — Storage Does Work

**What:** Controllers handle request/response parsing only. All business logic lives in storage roles or dedicated service modules.

**When to use:** Any time a controller calls more than one storage method or builds complex data structures.

**Trade-offs:** Requires discipline. The reflex to add logic to controllers is strong. But business logic in controllers can't be unit tested without an HTTP stack.

**Current violation example (Settings.pm):**
```perl
# Settings controller currently rebuilds notifiers, validates LDAP,
# and persists config all inline — 1,121 lines result.
sub update_slack {
    my ($self, $c) = @_;
    $self->safe_execute($c, sub {
        my $params = $c->req->json;
        # 40 lines of validation, nested conditionals, callback invocations
    });
}
```

**Target pattern:**
```perl
# Controller: parse, delegate, respond
sub update_slack {
    my ($self, $c) = @_;
    $self->safe_execute($c, sub {
        my $params = $c->req->json;
        my $result = $self->settings->update_notification('slack', $params);
        $self->rebuild_notifiers->() if $result->{changed};
        $c->render(json => { status => 'ok' });
    });
}
```

### Pattern 2: Moo Role Composition for Storage Domains

**What:** Each storage domain (alerts, patterns, backup, etc.) is a `Moo::Role` consumed by the main ClickHouse class. Roles are files of 100-300 lines, each with a single domain focus.

**When to use:** Already established in this codebase — continue the pattern. Do NOT add more methods to the main `ClickHouse.pm` class body.

**Trade-offs:** Role method resolution can surprise developers new to Moo. The 11-role class already at 1,316 lines suggests the main class is accumulating attribute state it shouldn't own — but the role split itself is correct.

**Example (correct pattern):**
```perl
# Purl::Storage::ClickHouse::Backup (Moo::Role)
package Purl::Storage::ClickHouse::Backup;
use Moo::Role;
# Only backup-domain methods here. No connection or cache logic.
sub create_backup { ... }
sub list_backups  { ... }
sub restore_backup { ... }
```

### Pattern 3: Safe Execute Wrapper — Uniform Error Handling

**What:** All controller action methods wrap logic in `$self->safe_execute($c, sub { ... })`. This catches die/croak, logs the error, and returns a consistent 500 JSON response.

**When to use:** Every controller action without exception.

**Trade-offs:** Swallows all exceptions identically — a ClickHouse timeout looks like a coding bug. In the refactoring phase, add error type detection inside `safe_execute` to distinguish 400 (user error), 503 (dependency unavailable), and 500 (internal bug).

**Enhancement for refactoring:**
```perl
sub safe_execute {
    my ($self, $c, $cb) = @_;
    eval { $cb->() };
    if (my $err = $@) {
        if (ref $err && $err->isa('Purl::Error::NotFound')) {
            return $self->render_error($c, $err->message, 404);
        }
        if (ref $err && $err->isa('Purl::Error::Validation')) {
            return $self->render_error($c, $err->message, 400);
        }
        $self->render_error($c, "Internal Server Error: $err", 500);
    }
}
```

### Pattern 4: In-Memory Storage Mock for Integration Tests

**What:** `t/25_integration_flow.t` defines `Purl::Storage::InMemory` inline — a full mock implementing the storage interface. The real storage class is monkey-patched out before app setup. This enables full HTTP-stack integration tests without a running ClickHouse.

**When to use:** All integration tests (HTTP-level). Unit tests mock individual components. This pattern should be formalized — move `InMemory` to `lib/Purl/Storage/InMemory.pm` and reuse across test files.

**Trade-offs:** In-memory mock can drift from real storage behavior. Must verify mock methods match real storage signatures when new storage methods are added.

**Build implication:** The mock currently contains method stubs that would fail silently if the real interface changes. Adding a role or interface check (`does()`) would catch drift early.

### Pattern 5: Svelte Store as Single Source of Truth

**What:** Each domain has one writable store. Components subscribe reactively. All API calls live in store files (or will be extracted to `api/` modules). No component fetches data directly.

**When to use:** Already established. The gap to fix is stores that do both fetching AND state — separate these into `api/logs.js` (pure fetch) and `stores/logs.js` (pure state + derived values).

**Trade-offs:** The current single-file approach (`stores/logs.js` at ~300+ lines) works but makes testing difficult. Splitting `fetch` from `state` enables unit testing of fetch logic without Svelte.

## Data Flow

### Ingest Flow

```
POST /api/logs (with X-API-Key or session)
    |
    v
Auth Middleware → validate API key hash (SHA256 lookup)
    |
    v
Logs Controller → parse JSON/NDJSON, decompress gzip
    |
    v
apply defaults (level=INFO, service=unknown, timestamp=now)
    |
    v
Storage::ClickHouse → buffer log (in-memory _buffer array)
    |
    v
maybe_flush() → if buffer >= 5000 or last_flush > 1s:
    HTTP INSERT to ClickHouse (synchronous HTTP::Tiny)
    |
    v
_broadcast_logs() → broadcaster->publish() → WebSocket subscribers
    |
    v
Response: { status: 'ok', inserted: N }
```

### Query Flow

```
GET /api/logs?q=level:ERROR&range=1h
    |
    v
Auth Middleware → session or API key
    |
    v
License Middleware → inject license_info into stash
    |
    v
NamespaceScope → inject namespace filter
    |
    v
Logs Controller → parse q param, time range
    |
    v
Base::get_cached("query:{md5}:{range}") → cache hit? return cached
    |
    v
Storage::ClickHouse::Query → build SQL with whitelist-validated fields
    |
    v
HTTP GET to ClickHouse → parse TSV response → build hit array
    |
    v
Base::set_cached(result, ttl=60)
    |
    v
Response: { hits: [...], total: N, query: '...', histogram: [...] }
```

### Frontend State Flow

```
User action (search input, time range change)
    |
    v
Component calls store action: searchLogs()
    |
    v
Store sets loading=true, aborts previous AbortController
    |
    v
fetch('/api/logs?...') with credentials
    |
    v
On success: logs.set(hits), total.set(N), loading.set(false)
On error: error.set(message), loading.set(false)
    |
    v
All subscribed components reactively re-render
```

### Settings Callback Flow (Currently Fragile)

```
PUT /api/settings/notifications/slack
    |
    v
Settings Controller → persist to Config.pm (settings.json)
    |
    v
rebuild_notifiers callback() → re-instantiate Telegram/Slack/Webhook
    |
    v (if exception in any callback → entire update fails, no rollback)
Response: { status: 'ok' }
```

**Refactoring target:** Wrap each callback in eval, return per-callback success/failure status. Add rollback (save old settings before update, restore on failure).

## Component Boundaries That Need Strengthening

### Boundary 1: Settings Controller — Must Split

**Current:** `Controller::Settings` owns 25+ setting categories (1,121 lines). Any settings change requires reasoning about the entire file.

**Target:** Four controllers, each responsible for one config domain:

| New Controller | Endpoints | Callbacks |
|----------------|-----------|-----------|
| `Settings::Database` | GET/PUT clickhouse, redis | rebuild_storage |
| `Settings::Notifications` | GET/PUT slack, telegram, webhook | rebuild_notifiers |
| `Settings::Auth` | GET/PUT users, passwords, LDAP, SAML | rebuild_ldap, rebuild_saml |
| `Settings::Integrations` | GET/PUT k8s, agents, pipeline, backup | no rebuild needed |

**Build order implication:** Do NOT split until the base helper methods are extracted into `Settings::Base` first. Splitting without shared helpers creates duplication.

### Boundary 2: Auth Middleware — Rate Limiting Must Exit

**Current:** `Middleware::Auth` handles API key verification, session auth, CSRF token generation, rate limiting, and failed login tracking — five distinct concerns in one class.

**Target:** Extract `Purl::API::Middleware::RateLimit` as a standalone class with its own state, cleanup job, and tests. Auth middleware calls it but does not own its state.

**Why this matters:** In-memory rate limit state leaks (no cleanup job for expired entries). This is easier to fix in an isolated class than in the 400-line Auth middleware.

### Boundary 3: Validation — Must Leave Storage Roles

**Current:** `_validate_field`, `_validate_level`, `_sanitize_identifier` live in `Storage::ClickHouse::Query` (a role). Other modules that need validation must consume the Query role — a wrong dependency.

**Target:** `Purl::Validation` module with exported functions. Used by Query role AND controllers AND any future modules.

```perl
# lib/Purl/Validation.pm
package Purl::Validation;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(validate_field validate_level sanitize_identifier);

my %ALLOWED_FIELDS = map { $_ => 1 } qw(level service host timestamp message ...);

sub validate_field {
    my ($field) = @_;
    # extracted logic from Query.pm
}
```

### Boundary 4: Server.pm Package Globals — Must Become Instance State

**Current:** `Server.pm` uses package-level variables (`my $storage`, `my $settings`, `my $websockets`, `my %metrics`, `my %notifiers`). This makes the app a singleton — impossible to instantiate twice in tests without module reloading.

**Target:** These must become instance attributes of a `Purl::API::Server` object. The `create()` factory (already partially exists based on test usage) should own all state.

**Why this matters for testing:** The integration test file (`t/25_integration_flow.t`) already monkey-patches `_build_storage` to inject a mock. This only works because package globals are set at `setup_routes()` time. If storage were an instance attribute with proper constructor injection, no monkey-patching would be needed.

## Refactoring Order (Dependencies First)

The order below is critical — later items depend on earlier items being stable.

### Phase 1: Foundation (No breakage risk)

1. **Extract `Purl::Validation`** from `Storage::ClickHouse::Query`
   - Zero breakage risk: replace internal calls with module calls
   - Unlocks independent unit testing of validation logic

2. **Fix `Controller::Base::safe_execute`** to handle typed exceptions
   - Add `Purl::Error::*` exception classes (NotFound, Validation, Forbidden)
   - All controllers benefit immediately without changes

3. **Move `Purl::Storage::InMemory`** from inline test code to `lib/`
   - Required before any further test expansion
   - Enables reuse across all test files

### Phase 2: Split High-Risk God Classes

4. **Split `Controller::Settings`** into 4 sub-controllers
   - Prerequisite: create `Controller::Settings::Base` with shared helpers first
   - Update `Server.pm` route registrations (mechanical change)
   - Test each sub-controller independently

5. **Extract `RateLimit` from `Middleware::Auth`**
   - Create `Middleware::RateLimit` with state, cleanup, and tests
   - Auth middleware delegates to it
   - Add cleanup job (periodic hash purge)

### Phase 3: Infrastructure Hardening

6. **Fix `Server.pm` package globals → instance attributes**
   - Required for proper dependency injection
   - Enables test isolation without monkey-patching

7. **Fix session secret persistence** (ephemeral → config/server.json)

8. **Fix broadcast silent fallback** — fail startup in cluster mode if Redis unavailable

### Phase 4: Frontend Architecture

9. **Extract `api/` layer from stores**
   - `api/logs.js`, `api/auth.js`, `api/settings.js` with pure fetch functions
   - Stores become pure state (writable + derived)

10. **Extract Router from `App.svelte`**
    - Move page routing to `Router.svelte`
    - App.svelte becomes auth check + mount only

## Test Architecture

### Three-Layer Test Strategy

```
┌──────────────────────────────────────────────────┐
│  API Tests (Test::Mojo)                          │
│  t/25_integration_flow.t, t/edge_cases_*.t       │
│  Full HTTP stack, InMemory storage mock          │
│  Tests: routing, auth, status codes, headers     │
├──────────────────────────────────────────────────┤
│  Controller Unit Tests                           │
│  t/1[3-9]_controller_*.t, t/controller/*.t       │
│  Direct controller instantiation, mock context  │
│  Tests: action logic, parameter parsing          │
├──────────────────────────────────────────────────┤
│  Module Unit Tests                               │
│  t/01-12_*, t/middleware_*.t, t/broadcast_*.t   │
│  No HTTP stack, no storage                       │
│  Tests: validation, time parsing, auth logic     │
└──────────────────────────────────────────────────┘
```

### Current Test Coverage Gaps

| Area | Gap | Priority |
|------|-----|----------|
| Settings controller | No test for callback exceptions or rollback | High |
| Auth cleanup | No test for in-memory state growth/cleanup | High |
| Storage failover | No test for ClickHouse unavailable at startup | High |
| Alert deduplication | No test for rapid successive triggers | Medium |
| WebSocket race | No test for concurrent subscriber modification | Medium |
| CSRF enforcement | No test confirming POST endpoints reject missing token | High |
| Config atomic write | No test for concurrent config saves | Medium |

### Controller Test Pattern (Recommended)

The current controller tests inline mock objects (`MockCtrl`, `MockStorage`) directly. This works but creates duplication. After `InMemory` is extracted to `lib/`, controller tests should use it consistently:

```perl
# Recommended controller test pattern
use Purl::Storage::InMemory;
use Purl::API::Controller::Alerts;

my $storage = Purl::Storage::InMemory->new;
my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);

# Test via mock Mojolicious context
my $c = MockContext->new(params => { page => 1 });
$ctrl->list($c);
is $c->rendered->{status}, 200;
```

### Integration Test Pattern (Already Good)

`t/25_integration_flow.t` is the correct approach: Test::Mojo against full app with InMemory storage. This pattern should be expanded to cover:
- Auth flows (login, session expiry, lockout)
- Feature gating (free/pro/enterprise plan differences)
- Settings updates with callback verification
- WebSocket subscription and message delivery

## Anti-Patterns

### Anti-Pattern 1: Package-Level Mutable State in Mojolicious App

**What people do:** Store `$storage`, `%metrics`, `$broadcaster` as `my` variables at package scope in `Server.pm`.

**Why it's wrong:** Makes the app class a singleton. Tests must monkey-patch to inject mocks. Multiple test files interfere with each other through shared state. Impossible to run two app instances in the same process (needed for some test patterns).

**Do this instead:** Make them instance attributes of `Purl::API::Server`. Use constructor injection: `Purl::API::Server->new(storage => $mock)`. This is how `t/25_integration_flow.t` already tries to use it — the `create()` pattern is correct, the package globals must go.

### Anti-Pattern 2: God Controller (1,000+ Line Settings)

**What people do:** Add each new settings endpoint as a method in the existing `Settings.pm` because it's "settings-related."

**Why it's wrong:** Settings for database, users, LDAP, and Slack share nothing except the word "settings." Each has different validation, different callbacks, different test requirements. One change to LDAP code can break database settings tests.

**Do this instead:** Split by domain (`Database`, `Auth`, `Notifications`, `Integrations`). The Mojolicious route prefix unifies them from the URL perspective. The code stays isolated per domain.

### Anti-Pattern 3: Validation Embedded in Storage Roles

**What people do:** Put input validation helpers (`_validate_field`, `_quote_string`) inside storage roles because "the storage class uses them."

**Why it's wrong:** Controllers and middleware also need input validation but cannot reuse storage role methods without adding a bogus dependency on the storage layer. Validation becomes untestable in isolation.

**Do this instead:** `Purl::Validation` module with exported functions. Zero dependencies. Consumed by storage roles, controllers, and middleware independently.

### Anti-Pattern 4: Silent Fallback Masking Configuration Errors

**What people do:** Try Redis, fail silently, fall back to local broadcast with a `warn` log line. Treat this as graceful degradation.

**Why it's wrong:** In a multi-replica deployment, silent fallback means live tail stops working across replicas. The operator set `PURL_REDIS_URL` expecting Redis to work. Silent fallback hides misconfiguration that affects users.

**Do this instead:** In single-server mode, silent fallback is acceptable (it's a single node with local broadcast). In cluster mode (detect via `PURL_BROADCAST_MODE=redis` or multiple replicas), fail startup with a clear error: `"Redis required in cluster mode but unavailable: <error>"`.

### Anti-Pattern 5: Store Files That Mix Fetching and State

**What people do:** Define writable stores AND async `fetch()` calls AND derived state AND error handling all in `stores/logs.js` (growing to 300+ lines).

**Why it's wrong:** Cannot unit test fetch logic without Svelte's store machinery. Cannot swap API endpoints without touching state logic. Cannot test error handling without triggering the full store subscription chain.

**Do this instead:** Thin stores (state only) + separate `api/logs.js` (fetch only). The store calls `api.fetchLogs(params)` and sets state from the result. The API module is testable with plain `fetch` mocks.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| ClickHouse | HTTP API (GET query, POST INSERT) via HTTP::Tiny | Synchronous — blocks Mojo worker. Async upgrade is Phase 3+ work |
| Telegram | HTTP POST to Bot API | Fire-and-forget, retries up to 3x |
| Slack | HTTP POST to Incoming Webhook URL | Same as Telegram |
| Webhook | HTTP POST to user-configured URL | Configurable timeout |
| Redis | TCP via Mojo::Redis (optional) | Only for multi-replica WebSocket sync |
| S3 | AWS SDK or HTTP presigned URLs | Backup only |
| LDAP | Net::LDAP bind+search | Enterprise feature, no pooling |
| License API | HTTPS to purlogs.com/api/activate | JWT RS256 response |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Controller → Storage | Direct method call (Moo object) | Storage injected at construction |
| Controller → Notifiers | Callback closures via Settings controller | Fragile — no transaction semantics |
| Auth → License | Direct method call after wiring in setup_routes | License middleware injected into Auth via setter |
| Server → Broadcaster | Package-level singleton (needs to become instance attr) | Logs controller holds reference |
| Frontend Store → Backend | HTTP fetch + WebSocket | WebSocket for live tail only |

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| Single server (current) | Current architecture is appropriate. Fix correctness bugs first. |
| 2-5 replicas | Redis broadcast becomes required (not optional). Session secret must be shared (env var, not ephemeral). Config changes must propagate (pub/sub or external config store). |
| 5+ replicas + HA | ClickHouse cluster mode (already supported via `cluster_name`). Alert evaluation must move to a dedicated worker process (not embedded in web process). Storage layer needs async HTTP. |

### First Bottleneck: Synchronous ClickHouse HTTP

The most impactful performance constraint in the current architecture is that every ClickHouse query blocks a Mojolicious worker thread. HTTP::Tiny is synchronous. A slow query (2-3 seconds) holds one worker for its duration.

Mitigation order:
1. **Cache aggressively** (already done for search, extend to field stats and patterns)
2. **Short-circuit fast** (validate query parameters before hitting storage; return 400 early)
3. **Query timeout enforcement** (already exists: `max_execution_time=30s` but never surfaced as 503 to client)

Async HTTP (Mojo::UserAgent or Mojo::Promise) is the correct long-term fix but is a significant refactor. Do not prioritize in this milestone.

## Sources

- Direct codebase analysis: `lib/`, `web/src/`, `t/` directories (2026-03-10)
- Mojolicious documentation on full vs. Lite app structure: https://docs.mojolicious.org/Mojolicious/Guides/Growing
- Moo role composition patterns: https://metacpan.org/pod/Moo#ROLES
- Test::Mojo integration test patterns: https://docs.mojolicious.org/Test/Mojo

---
*Architecture research for: Purl log aggregation platform — quality hardening milestone*
*Researched: 2026-03-10*
