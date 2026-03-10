# Codebase Structure

**Analysis Date:** 2026-03-10

## Directory Layout

```
purl/
├── lib/Purl/                           # Perl backend modules
│   ├── API/
│   │   ├── Server.pm                   # Entry point, route definitions, middleware setup
│   │   ├── Controller/                 # 25+ request handlers
│   │   │   ├── Base.pm                 # Base class: cache, error handling, feature gating
│   │   │   ├── Logs.pm                 # Log search, ingest, context, WebSocket tail
│   │   │   ├── Alerts.pm               # Alert CRUD, rule evaluation, notifications
│   │   │   ├── Patterns.pm             # Pattern detection (template hashing)
│   │   │   ├── Dashboard.pm            # Dashboard CRUD, widget execution
│   │   │   ├── Pipeline.pm             # Log transformation pipelines
│   │   │   ├── Settings.pm             # Admin settings (users, notifications, license)
│   │   │   ├── Auth.pm                 # Login, logout, password change
│   │   │   ├── Analytics.pm            # Query metrics, notifier monitoring
│   │   │   ├── Stats.pm                # Field statistics, histograms
│   │   │   ├── SavedSearches.pm        # Saved query management
│   │   │   ├── Traces.pm               # OpenTelemetry traces
│   │   │   ├── K8sHealth.pm            # Kubernetes cluster health
│   │   │   ├── K8sAudit.pm             # K8s audit webhook receiver
│   │   │   ├── OTLP.pm                 # OpenTelemetry Protocol ingestion
│   │   │   ├── Syslog.pm               # RFC 3164/5424 syslog receiver
│   │   │   ├── ESCompat.pm             # Elasticsearch-compatible API
│   │   │   ├── Backup.pm               # Backup/restore, S3 upload
│   │   │   ├── Audit.pm                # Audit log retrieval
│   │   │   ├── Config.pm               # Configuration endpoints
│   │   │   ├── System.pm               # Health, metrics endpoints
│   │   │   ├── AI.pm                   # AI operations (log analysis)
│   │   │   ├── Agents.pm               # Agent registration, heartbeat
│   │   │   ├── Clusters.pm             # Multi-cluster management
│   │   │   ├── AlertTemplates.pm       # Alert template library
│   │   │   └── (others)
│   │   └── Middleware/
│   │       ├── Auth.pm                 # Session + API key validation, rate limiting
│   │       ├── License.pm              # JWT license verification, feature gating
│   │       ├── LDAP.pm                 # LDAP/AD authentication
│   │       ├── SAML.pm                 # SAML 2.0 SSO
│   │       └── NamespaceScope.pm       # Multi-tenant namespace filtering
│   ├── Storage/
│   │   ├── ClickHouse.pm               # Main storage class (consumes roles)
│   │   ├── S3.pm                       # S3 backup uploader
│   │   └── ClickHouse/
│   │       ├── Query.pm                # Log search, field stats, histogram
│   │       ├── Cache.pm                # Cache expiry management
│   │       ├── Alerts.pm               # Alert CRUD, evaluation
│   │       ├── Patterns.pm             # Pattern detection (MD5 hashing)
│   │       ├── Audit.pm                # Audit event logging
│   │       ├── Dashboard.pm            # Dashboard widget execution
│   │       ├── SavedSearches.pm        # Saved query storage
│   │       ├── Backup.pm               # Snapshot creation, S3 manifest
│   │       ├── Pipeline.pm             # Pipeline execution
│   │       ├── K8sHealth.pm            # Kubernetes health metrics
│   │       ├── Agents.pm               # Agent task distribution
│   │       └── (others)
│   ├── Alert/
│   │   ├── Base.pm                     # Abstract notifier base class
│   │   ├── Telegram.pm                 # Telegram bot sender
│   │   ├── Slack.pm                    # Slack webhook sender
│   │   └── Webhook.pm                  # Generic HTTP POST sender
│   ├── Broadcast/
│   │   ├── Local.pm                    # In-memory broadcast (default)
│   │   └── Redis.pm                    # Redis Pub/Sub broadcast
│   ├── Config.pm                       # Settings file loader/writer (JSON)
│   ├── Util/
│   │   ├── Time.pm                     # Time range parsing (15m, 1h, etc.)
│   │   └── (helpers)
│   ├── Pipeline/
│   │   └── Engine.pm                   # Log transformation engine
│   ├── AI/
│   │   └── Provider/                   # LLM providers (OpenAI, Claude, etc.)
│   └── (package root)
├── web/                                # Svelte 5 frontend
│   ├── src/
│   │   ├── App.svelte                  # Root component: page routing, menu
│   │   ├── main.js                     # Svelte mount entrypoint
│   │   ├── stores/
│   │   │   ├── logs.js                 # Log search state (query, range, results)
│   │   │   ├── auth.js                 # Current user, login state
│   │   │   ├── license.js              # Plan, features, trial
│   │   │   ├── settings.js             # UI preferences (max results, refresh)
│   │   │   ├── dashboard.js            # Dashboard state, widgets
│   │   │   ├── ai.js                   # AI provider configuration
│   │   │   ├── cluster.js              # Cluster selection
│   │   │   ├── k8sHealth.js            # K8s health metrics
│   │   │   └── toast.js                # Toast notifications
│   │   ├── components/
│   │   │   ├── SearchBar.svelte        # Query input + execute
│   │   │   ├── TimeRangePicker.svelte  # Date range selector
│   │   │   ├── Histogram.svelte        # Time distribution chart
│   │   │   ├── FieldsSidebar.svelte    # Field explorer + facets
│   │   │   ├── PatternsSidebar.svelte  # Pattern browser
│   │   │   ├── SavedSearches.svelte    # Saved query list
│   │   │   ├── AlertsPanel.svelte      # Alert rules editor
│   │   │   ├── LogTable.svelte         # Main log grid (log/ subdir)
│   │   │   ├── AnalyticsPage.svelte    # Query metrics, performance
│   │   │   ├── DashboardPage.svelte    # Dashboard editor (dashboard/ subdir)
│   │   │   ├── TracesPage.svelte       # OpenTelemetry traces
│   │   │   ├── K8sPage.svelte          # Kubernetes health
│   │   │   ├── QueryPage.svelte        # SQL/ClickHouse query builder
│   │   │   ├── LoginPage.svelte        # Auth form
│   │   │   ├── SearchHelp.svelte       # Query syntax help
│   │   │   ├── ui/                     # Reusable components
│   │   │   │   ├── Modal.svelte        # Modal dialog
│   │   │   │   ├── Button.svelte       # Styled button
│   │   │   │   ├── Input.svelte        # Text input
│   │   │   │   ├── Select.svelte       # Dropdown
│   │   │   │   ├── Toggle.svelte       # Checkbox/toggle
│   │   │   │   ├── Toast.svelte        # Toast notification
│   │   │   │   ├── LoadingSpinner.svelte # Spinner
│   │   │   │   ├── Card.svelte         # Card container
│   │   │   │   ├── Badge.svelte        # Tag/badge
│   │   │   │   ├── Tooltip.svelte      # Tooltip
│   │   │   │   ├── ConfirmDialog.svelte # Confirmation modal
│   │   │   │   └── ClusterSelector.svelte # Multi-cluster switcher
│   │   │   ├── settings/               # Settings pages
│   │   │   │   ├── SettingsPage.svelte # Settings router
│   │   │   │   ├── LicenseSettings.svelte
│   │   │   │   ├── UserSettings.svelte
│   │   │   │   ├── DatabaseSettings.svelte
│   │   │   │   ├── NotificationSettings.svelte
│   │   │   │   ├── ApiKeysSettings.svelte
│   │   │   │   ├── SSOSettings.svelte
│   │   │   │   ├── LdapSettings.svelte
│   │   │   │   ├── RedisSettings.svelte
│   │   │   │   ├── AISettings.svelte
│   │   │   │   └── (others)
│   │   │   ├── dashboard/              # Dashboard components
│   │   │   │   ├── DashboardPage.svelte
│   │   │   │   ├── WidgetEditor.svelte
│   │   │   │   └── (widget types)
│   │   │   ├── log/                    # Log display components
│   │   │   │   ├── LogTable.svelte
│   │   │   │   ├── LogRow.svelte
│   │   │   │   └── LogDetail.svelte
│   │   │   ├── alerts/                 # Alert components
│   │   │   │   ├── AlertsPanel.svelte
│   │   │   │   └── AlertRule.svelte
│   │   │   ├── k8s/                    # Kubernetes components
│   │   │   │   ├── K8sPage.svelte
│   │   │   │   └── NodeHealth.svelte
│   │   │   └── ai/                     # AI components
│   │   │       ├── AISidebar.svelte
│   │   │       └── AnalysisResult.svelte
│   │   ├── utils/
│   │   │   ├── format.js               # Number/date formatting
│   │   │   ├── colors.js               # Theme colors, log level colors
│   │   │   ├── dom.js                  # DOM utilities (escapeHtml)
│   │   │   └── (helpers)
│   │   ├── styles/
│   │   │   └── *.css                   # Global + component styles (dark theme)
│   ├── public/
│   │   ├── index.html                  # HTML shell (mounts #app div)
│   │   └── assets/                     # Static files (logo, etc.)
│   ├── dist/                           # Built SPA (production)
│   ├── node_modules/                   # npm packages
│   ├── package.json                    # npm dependencies
│   ├── vite.config.js                  # Vite build config
│   ├── eslint.config.js                # ESLint rules
│   └── playwright.config.js            # Playwright e2e test config
├── t/                                  # Perl unit tests
│   ├── 01_*.t                          # Core modules tests
│   ├── 06_middleware_auth.t
│   ├── 07_middleware_functional.t
│   ├── 08_middleware_license.t
│   ├── 12_alert_webhook.t
│   ├── 18_controller_traces.t
│   ├── 22_controller_stats.t
│   ├── middleware_saml.t
│   ├── k8s_health.t
│   ├── controller/
│   │   └── (controller-specific tests)
│   └── ai/
│       └── (AI provider tests)
├── tests/                              # Frontend integration tests
│   └── e2e/                            # Playwright e2e tests
├── docker/                             # Docker build context
│   ├── clickhouse/                     # ClickHouse Docker compose
│   ├── auth-test/                      # LDAP/Keycloak test fixtures
│   └── (docker configs)
├── deploy/                             # Deployment configs
│   ├── kubernetes/                     # K8s manifests, Helm
│   ├── nginx/                          # Reverse proxy config
│   ├── grafana/                        # Grafana dashboards
│   ├── vector/                         # Vector collector config
│   └── backup/                         # Backup scripts
├── chart/                              # Helm chart
│   └── templates/                      # K8s manifests
├── config/                             # Runtime config (mounted volume)
│   ├── settings.json                   # Application settings (created on first run)
│   └── (user files, licenses)
├── scripts/                            # Helper scripts
├── .perlcriticrc                       # Perl linter config
├── .github/                            # GitHub Actions CI/CD
├── Dockerfile                          # Multi-stage Docker build
├── Makefile                            # Development tasks
├── cpanfile                            # Perl dependencies
├── package.json                        # Node dependencies
├── CLAUDE.md                           # Project guidelines
└── README.md                           # User documentation
```

## Directory Purposes

**lib/Purl/:**
- Purpose: All backend Perl modules (libraries, not executable)
- Contains: Controllers, middleware, storage, utilities
- Key files: `API/Server.pm` (entry), `Config.pm`, all module definitions
- Pattern: Namespace = directory structure (e.g., `Purl/API/Controller/Logs.pm` → `Purl::API::Controller::Logs`)

**lib/Purl/API/:**
- Purpose: Request/response handling and routing
- Contains: Server (routes), controllers (business logic), middleware (filters)
- Key: `Server.pm` instantiates middleware + controllers, registers routes with Mojolicious

**lib/Purl/API/Controller/:**
- Purpose: Request handlers (one per domain: Logs, Alerts, Dashboard, etc.)
- Pattern: All extend `Base.pm`, receive `$c` (Mojolicious controller context)
- Access: `$c->param()` (query params), `$c->req->json()` (body), `$c->render()` (response)

**lib/Purl/API/Middleware/:**
- Purpose: Request filtering and enrichment
- Pattern: Checked before route handler, return 0 to halt, return 1 to continue
- Executes: Authentication checks, license verification, audit logging

**lib/Purl/Storage/:**
- Purpose: Database abstraction layer
- Pattern: `ClickHouse.pm` is main class; `ClickHouse/*.pm` are roles (consume with `with`)
- Usage: Injected into all controllers as `$self->storage`
- Methods: Domain-specific queries (search_logs, list_alerts, get_patterns, etc.)

**lib/Purl/Alert/:**
- Purpose: Outbound notification implementations
- Pattern: Base class defines interface, subclasses implement `send()`
- Instantiation: Lazy-loaded at startup if credentials provided

**web/src/:**
- Purpose: Svelte 5 frontend source
- Contains: Components (`.svelte`), stores (reactive state), utilities

**web/src/stores/:**
- Purpose: Global reactive state (Svelte writable stores)
- Pattern: Exported functions mutate store values, components import and subscribe
- Example: `searchLogs()` function fetches API, updates `logs` + `loading` stores

**web/src/components/:**
- Purpose: Reusable UI components
- Pattern: Top-level pages (AnalyticsPage, DashboardPage, etc.), then subdirs for logical groups
- ui/: Generic components (Modal, Button, Input) used across pages
- Subdirs: Page-specific components grouped by feature

**t/:**
- Purpose: Unit tests for Perl modules
- Pattern: `0N_*.t` for core tests, functional tests separate
- Runner: `prove -r t/` (TAP test harness)
- Coverage: Controllers, middleware, storage, alerts, utilities

**tests/:**
- Purpose: Frontend e2e tests
- Pattern: Playwright (browser automation)
- Runner: `npx playwright test`

**config/:**
- Purpose: Runtime configuration (mounted volume in Docker)
- Files: `settings.json` (created on first run), user files, backup manifests
- Persisted: Survives container restarts (Docker volume)

**deploy/:**
- Purpose: Deployment manifests and configurations
- Contains: Kubernetes YAMLs, Helm values, Nginx configs, Vector collectors
- Usage: `docker compose up` (local), `kubectl apply` (K8s), Helm for production

## Key File Locations

**Entry Points:**

Backend:
- `lib/Purl/API/Server.pm` (Perl) — Mojolicious app initialization, route setup, starts listening on port 3000

Frontend:
- `web/src/main.js` (JavaScript) — Mounts Svelte app to DOM
- `web/public/index.html` (HTML) — HTML shell with `<div id="app"></div>`

**Configuration:**

- `config/settings.json` (JSON) — User settings, database config, auth users, API keys (created at runtime)
- `lib/Purl/Config.pm` (Perl) — Config loader/writer class
- `web/eslint.config.js` (JavaScript) — ESLint rules
- `.perlcriticrc` (INI) — Perl linting rules
- `cpanfile` (Perl) — Perl dependencies (like package.json for Perl)
- `package.json` (JSON) — Node dependencies, build scripts

**Core Logic:**

Backend:
- `lib/Purl/Storage/ClickHouse.pm` — Main DB query class (roles for different domains)
- `lib/Purl/API/Middleware/Auth.pm` — Authentication logic
- `lib/Purl/API/Controller/Base.pm` — Base class for all controllers

Frontend:
- `web/src/stores/logs.js` — Search state and API calls
- `web/src/stores/auth.js` — User session management
- `web/src/components/SearchBar.svelte` — Main search UI

**Testing:**

Backend:
- `t/06_middleware_auth.t` — Auth middleware tests
- `t/08_middleware_license.t` — License verification tests
- `t/18_controller_traces.t` — Traces controller tests

Frontend:
- `web/e2e/` — Playwright e2e tests
- `tests/e2e/` — Additional e2e tests

## Naming Conventions

**Files:**

- Perl modules: PascalCase (`Server.pm`, `Logs.pm`, `Base.pm`)
- Svelte components: PascalCase (`SearchBar.svelte`, `LogTable.svelte`)
- JavaScript utilities: camelCase (`format.js`, `colors.js`)
- Config files: kebab-case (`eslint.config.js`, `vite.config.js`)
- Test files: `0N_*.t` or `*_*.t` (e.g., `06_middleware_auth.t`)
- Directories: lowercase (`lib/`, `web/`, `deploy/`)

**Perl Packages:**

- Namespace matches directory: `lib/Purl/API/Controller/Logs.pm` → `Purl::API::Controller::Logs`
- Class names: PascalCase
- Methods: snake_case
- Constants/variables: lowercase with underscores

**JavaScript:**

- Variables/functions: camelCase
- Components: PascalCase
- Stores: camelCase with export keyword (e.g., `export const logs = writable([])`)
- Utility functions: camelCase

**Routes (REST API):**

- Pattern: `/api/<domain>/<resource>/<action>`
- Examples:
  - `/api/logs` (GET search, POST ingest)
  - `/api/alerts/:id` (GET, PUT, DELETE)
  - `/api/settings/<section>` (GET, PUT)
  - `/api/auth/login`, `/api/auth/logout`
  - `/api/dashboards/:id/widgets` (GET)

## Where to Add New Code

**New Feature (API + UI):**

1. Backend logic:
   - Create `lib/Purl/API/Controller/YourFeature.pm` extending `Base.pm`
   - Add methods for each endpoint
   - Implement storage queries in new role `lib/Purl/Storage/ClickHouse/YourFeature.pm`
   - Add routes to `lib/Purl/API/Server.pm` under `$protected->get/post/put/delete`

2. Frontend:
   - Create `web/src/components/YourFeaturePage.svelte` (main page component)
   - Create feature store `web/src/stores/yourFeature.js` for state
   - Add page routing case in `web/src/App.svelte`
   - Add UI sub-components in `web/src/components/yourFeature/` directory

3. Tests:
   - Backend: `t/controller_your_feature.t` or add to existing controller test
   - Frontend: `tests/e2e/your-feature.spec.ts`

**New Component/Module:**

- Reusable UI: `web/src/components/ui/YourComponent.svelte`
- Settings page: `web/src/components/settings/YourSettings.svelte`
- Utility: `lib/Purl/Util/YourHelper.pm`

**Middleware:**

- New cross-cutting concern: `lib/Purl/API/Middleware/YourMiddleware.pm`
- Register in `Server.pm` setup_routes, apply to route group via `under()` filter
- Example: Rate limiting → checked via `$auth_middleware->check_rate_limit()`

**Utilities:**

Shared helpers:
- Time parsing: `lib/Purl/Util/Time.pm` (already used everywhere)
- DOM utils: `web/src/utils/dom.js` (escapeHtml, etc.)
- Colors: `web/src/utils/colors.js` (log level colors, theme)

Only create utility if used in 2+ places. Otherwise, keep logic in the controller/component.

**Storage Queries:**

Domain-specific queries in roles:
- Create `lib/Purl/Storage/ClickHouse/YourDomain.pm` (role)
- Define methods: `search_your_domain()`, `list_your_domain()`, etc.
- Add `with 'Purl::Storage::ClickHouse::YourDomain'` to main Storage class
- Access via `$self->storage->search_your_domain()`

## Special Directories

**node_modules/, .perles/:**
- Purpose: Dependency caches
- Generated: Yes (by npm/carton)
- Committed: No (git-ignored)
- Regenerate: `npm install`, `carton install`

**config/:**
- Purpose: Runtime configuration and secrets
- Generated: Yes (settings.json created on first run)
- Committed: No (volume-mounted in Docker, never checked in)
- User files: API keys, auth users, license key stored here

**dist/, web/dist/:**
- Purpose: Built artifacts
- Generated: Yes (by Vite, Webpack, or make)
- Committed: No (rebuilt on deploy)
- Command: `make web-build` regenerates

**.git/, .github/:**
- Purpose: Version control and CI/CD
- Generated: Yes (git history, workflow runs)
- Committed: Git metadata
- CI pipelines: `.github/workflows/*.yml`

**.planning/codebase/:**
- Purpose: Architecture documentation (this location)
- Generated: Yes (by `/gsd:map-codebase`)
- Committed: Yes (tracked in git)
- Consumer: `/gsd:plan-phase` and `/gsd:execute-phase`

---

*Structure analysis: 2026-03-10*
