# Architecture

**Analysis Date:** 2026-03-10

## Pattern Overview

**Overall:** Layered MVC + Role-based modular architecture

Purl follows a three-tier architecture with clear separation of concerns:
- **Presentation**: Svelte 5 SPA frontend with client-side routing
- **Application**: Mojolicious REST API with middleware-based request pipeline
- **Persistence**: ClickHouse time-series database + file-based settings config

**Key Characteristics:**
- Middleware-first authentication/authorization (API keys, sessions, JWT, LDAP, SAML)
- Role-based feature gating via JWT license verification
- Pluggable storage backends (ClickHouse primary, S3 for backups)
- WebSocket live-tail with in-memory or Redis broadcast
- Reactive Svelte stores for state management on frontend
- Per-controller inheritance from `Base` controller with shared caching

## Layers

**Frontend (Web):**
- Purpose: Interactive dashboard for log search, dashboards, alerts, settings
- Location: `web/src/`
- Contains: Svelte components, stores, utilities
- Depends on: Backend API (`/api/*`)
- Used by: End users via browser

**API Server (Application):**
- Purpose: Request routing, authentication, data transformation, business logic
- Location: `lib/Purl/API/Server.pm` (entry point + route definitions)
- Contains: Middleware stack, controller instantiation, route setup
- Depends on: Storage layer, Config, Alert modules
- Used by: Frontend, external clients (OTLP, Syslog, K8s audit webhooks)

**Controllers:**
- Purpose: Request handlers, API logic orchestration
- Location: `lib/Purl/API/Controller/`
- Contains: 25+ controllers (Logs, Alerts, Settings, Dashboard, Pipelines, etc.)
- Depends on: Storage, Middleware, Config
- Extends: `Purl::API::Controller::Base` (provides cache, error handling, feature gating)

**Middleware:**
- Purpose: Cross-cutting concerns (auth, licensing, audit, scope)
- Location: `lib/Purl/API/Middleware/`
- Contains: Auth (session + API key), License (JWT), LDAP, SAML, NamespaceScope, Broadcast
- Implements: Authentication, feature/plan enforcement, audit logging

**Storage Layer:**
- Purpose: Database abstraction and domain-specific queries
- Location: `lib/Purl/Storage/ClickHouse.pm` (main) + `lib/Purl/Storage/ClickHouse/*.pm` (roles)
- Contains: Query execution, caching, alerts, patterns, backups, audit logs
- Depends on: HTTP::Tiny (ClickHouse HTTP API), JSON::XS
- Used by: All controllers

**Config & Settings:**
- Purpose: Application configuration management
- Location: `lib/Purl/Config.pm` (file-based JSON), settings in ClickHouse
- Contains: Database connection, auth users, notifications, LDAP/SAML, API keys, license
- Persisted: `config/settings.json` (Docker mounted volume)

**Alert System:**
- Purpose: Outbound notifications for matched log patterns
- Location: `lib/Purl/Alert/`
- Contains: Base class + Telegram, Slack, Webhook implementations
- Triggered by: Alert rules via Controllers
- State: Notifiers initialized at startup in `Server.pm`

**Utility Modules:**
- Purpose: Shared helpers and time parsing
- Location: `lib/Purl/Util/`, `lib/Purl/Pipeline/`, `lib/Purl/AI/`, `lib/Purl/Broadcast/`

## Data Flow

**Ingest Flow (Logs → ClickHouse):**

1. Client → POST `/api/logs` (with Bearer token or API key)
2. `Logs` controller receives, validates, decompresses (gzip)
3. Parser extracts fields (level, service, host, message, meta)
4. `Storage::ClickHouse::Query` batches writes (buffered in memory)
5. Async flush: HTTP INSERT to ClickHouse (async, non-blocking)
6. Live tail: Broadcast logs to WebSocket subscribers via `Logs` controller
7. Pattern matching: `Storage::ClickHouse::Patterns` identifies message templates
8. Alert check: `Alerts` controller evaluates rules, fires Telegram/Slack/Webhook

**Search Flow (Query → Results):**

1. Client → GET `/api/logs?q=level:ERROR&range=1h`
2. `Logs` controller parses query (simple filter syntax: field:value, field:[min..max])
3. `Auth` middleware verifies session/API key + license features
4. `Settings::NamespaceScope` applies tenant/namespace filtering
5. `Storage::ClickHouse::Query` builds SQL, executes against ClickHouse
6. Results: 500 logs max (configurable), with field histograms
7. Response cached for 60s (unless query has live tail)

**Authentication Flow:**

1. Client → POST `/api/auth/login` {username, password}
2. `Auth` controller hashes password, compares against `config.json` users
3. Success: Set session cookie (Mojolicious signed session)
4. Middleware on protected routes: Verifies session or API key in header
5. Failed login: Tracked per-username, 5 attempts → 15m lockout

**License/Feature Flow:**

1. Startup: `License` middleware loads license key from env or config
2. Activation: POST to `https://purlogs.com/api/activate` with license key
3. Response: JWT RS256 signed token (plan, features, expiry)
4. Verification: Decodes JWT, validates signature against public key
5. Cache: In-memory 1h TTL
6. Feature gate: Controllers check via `$self->require_feature($c, 'feature_name')`
   - Free: Basic logs search, single user
   - Pro: Dashboards, alerts, patterns, 5 agents
   - Enterprise: LDAP, SAML, 50+ agents, audit logs

**State Management (Frontend):**

Svelte stores manage reactive state:
- `logs.js`: Search query, time range, results, loading
- `auth.js`: Current user, session
- `license.js`: Plan, features, trial status
- `settings.js`: UI preferences (max results, refresh interval)
- `dashboard.js`: Dashboard widgets, layout
- `ai.js`: AI provider state

Updates trigger API calls → store updates → component reactivity.

## Key Abstractions

**Controller Base Class:**
- Purpose: Shared request/response handling, caching, error safety
- Location: `lib/Purl/API/Controller/Base.pm`
- Pattern: Moo OOP with attributes: `storage`, `cache`, `namespace_scope`
- Methods: `safe_execute()` (eval wrapper), `render_error()`, `get_cached()`, `set_cached()`, `require_feature()`
- Example: `Purl::API::Controller::Logs` extends Base, calls `$self->storage->search_logs()`

**Storage Roles (Composition):**
- Purpose: Modular domain-specific queries without inheritance chains
- Location: `lib/Purl/Storage/ClickHouse/*.pm`
- Pattern: Moo roles consumed by main Storage class
- Examples:
  - `Query.pm`: Log search, field stats, histogram
  - `Cache.pm`: Cache key expiry
  - `Alerts.pm`: Alert CRUD, rule evaluation
  - `Patterns.pm`: Pattern detection (message template hashing)
  - `Audit.pm`: Audit event logging
  - `Dashboard.pm`: Dashboard widget execution
  - `Agents.pm`: Agent heartbeat, task distribution
  - `Backup.pm`: S3 snapshot management

**Middleware Pipeline:**
- Purpose: Request filtering and enrichment
- Location: `lib/Purl/API/Middleware/`
- Pattern: Mojolicious route filters + early-return on auth failure
- Examples:
  - `Auth.pm`: API key verification, session validation, rate limiting
  - `License.pm`: License key verification, feature availability
  - `LDAP.pm`: LDAP directory bind and search
  - `SAML.pm`: SAML 2.0 assertion parsing
  - `NamespaceScope.pm`: Multi-tenancy namespace filtering

**Notifier System:**
- Purpose: Pluggable alert delivery
- Location: `lib/Purl/Alert/Base.pm` + subclasses
- Pattern: Abstract base with `send()` method
- Subclasses: `Telegram`, `Slack`, `Webhook` (HTTP POST)
- Instantiation: Lazy-loaded at startup based on env vars or config

**Broadcast System:**
- Purpose: WebSocket distribution for live tail
- Implementations: `Purl::Broadcast::Local` (in-memory), `Purl::Broadcast::Redis`
- Default: Local if no Redis URL; Redis if connected; fallback to Local on failure
- Used by: `Logs` controller to publish new logs to subscribers

## Entry Points

**Backend:**
- Location: `lib/Purl/API/Server.pm`
- Invocation: Docker entrypoint runs Perl via Mojolicious standalone server
- Initialization:
  1. Load config from `config/settings.json`
  2. Build storage (ClickHouse connection pool)
  3. Instantiate middleware (Auth, License, LDAP, SAML)
  4. Instantiate 25+ controllers
  5. Register routes via `app->routes`
  6. Activate license (if key present)
  7. Create default admin user (if no users exist)
  8. Listen on `PURL_HOST:PURL_PORT` (default 0.0.0.0:3000)

**Frontend:**
- Location: `web/src/main.js`
- Invocation: Vite dev server or pre-built SPA from `web/dist/`
- Mount: Svelte root component to `#app` DOM element
- Initialization:
  1. Import `App.svelte` (root routing component)
  2. Fetch `/api/auth/me` to check session
  3. Fetch `/api/license` to determine plan features
  4. Setup stores (logs, auth, settings)
  5. Show `LoginPage` or main dashboard based on auth state

**Public Routes (No Auth):**
- `/api/csrf-token` — GET CSRF token for login form
- `/api/auth/login` — POST credentials
- `/api/auth/logout` — Destroy session
- `/api/auth/me` — GET current user info (returns 401 if no session)
- `/api/license` — GET plan, features, trial status
- `/api/health` — GET server status
- `/api/metrics` — GET Prometheus metrics

**Protected Routes (Require Auth):**
- `/api/logs` — GET (search), POST (ingest)
- `/api/patterns`, `/api/alerts`, `/api/saved-searches` — CRUD
- `/api/dashboards`, `/api/pipelines` — CRUD
- `/api/settings/*` — Admin settings
- `/api/agents` — Agent registration
- `/api/backup` — Backup management

## Error Handling

**Strategy:** Safe execution with detailed logging

**Patterns:**

1. **Controller error handling:**
   ```perl
   sub search {
       my ($self, $c) = @_;
       $self->safe_execute($c, sub {
           my $results = $self->storage->search_logs(...);
           $c->render(json => $results);
       });
   }
   ```
   - `safe_execute()` wraps callback in eval, catches die/exceptions
   - On error: Logs to app->log, responds with 500 + error message

2. **Middleware error handling:**
   - Early return if auth fails: `return 0` halts request
   - Responds with 401 (Unauthorized) or 403 (Forbidden)
   - Never throws; logs issue, moves to next middleware

3. **Storage query errors:**
   - HTTP timeout → Caught, retried up to 3x
   - Invalid SQL → Returns empty array + logs warning
   - Connection failed → Fallback to cache or error response

4. **Alert sending:**
   - Fire-and-forget: Webhook send failures don't break main flow
   - Retries: Up to 3 attempts for transient failures
   - Logs: All sends logged to audit trail

5. **Frontend error handling:**
   - API errors stored in `error` store
   - Auto-dismisses after 10s
   - Retry button provided for user
   - 401 → Redirect to login

## Cross-Cutting Concerns

**Logging:**
- Framework: Mojolicious `app->log` (writes to STDOUT/STDERR)
- Levels: info, warn, error
- Format: ISO timestamp, level, message
- Patterns:
  - Startup: License activation, storage init, notifier setup
  - Requests: IP, method, path, status, duration
  - Errors: Full stack trace for 5xx

**Validation:**
- Query params: Type coercion via Mojolicious, manual length checks
- JSON payload: Parse via `Mojo::JSON::decode_json()`, catch die on invalid
- API keys: SHA256 hash lookup in config
- Time ranges: Parsed by `Purl::Util::Time::parse_time_range()`

**Authentication:**
- Session cookies: Mojolicious signed session (secret persisted in config)
- API keys: `Authorization: Bearer <key>` header, hashed in config.json
- JWT (License): RS256 signature verification via public key env var
- LDAP: Bind + search against directory (Enterprise feature)
- SAML: SP-initiated flow with ACS callback (Enterprise feature)

**Caching:**
- Backend: Per-controller hash cache, 60s TTL (configurable)
- Keys: `"query:{hash}:{range}"` → Value expires at `time() + ttl`
- Invalidation: Manual via `/api/config` clear-cache endpoint
- Storage-level: ClickHouse query cache (internal)

**Rate Limiting:**
- Mechanism: IP-based token bucket in `Auth` middleware
- Default: 1000 requests/min per IP
- On limit: 429 response + `Retry-After` header
- Bypassable: Set `PURL_RATE_LIMIT=0` to disable

---

*Architecture analysis: 2026-03-10*
