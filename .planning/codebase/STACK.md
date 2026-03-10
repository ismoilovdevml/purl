# Technology Stack

**Analysis Date:** 2026-03-10

## Languages

**Primary:**
- Perl 5.24+ - Backend API, storage adapters, alert handlers, AI integrations
- JavaScript/ES6+ (Svelte 5) - Frontend dashboard UI

**Secondary:**
- SQL (ClickHouse dialect) - Data queries, schema definitions, aggregations
- YAML - Docker Compose configuration, Helm chart templates

## Runtime

**Environment:**
- Perl 5.024 minimum (tested on 5.40)
- Node.js 18+ (Vite build, dev server only)

**Package Manager:**
- Perl: cpanfile (Carton for dependency management)
- Node.js: npm 9+
- Lockfile: `cpanfile.lock` (Perl), `package-lock.json` (Node)

## Frameworks

**Core:**
- Mojolicious 9.0 - HTTP API framework, routing, WebSocket, middleware
- Svelte 5.16 - Frontend reactive component framework

**Build/Dev:**
- Vite 6.0+ - JavaScript bundler, HMR dev server
- Perl::Critic - Linting (config: `.perlcriticrc`)
- ESLint 9.17 - JavaScript linting (config: `web/eslint.config.js`)

**Testing:**
- Playwright 1.58+ - E2E browser testing (config: `web/playwright.config.js`)
- Perl prove - TAP test runner for unit tests (Makefile target: `make test`)

## Key Dependencies

**Critical - Backend (Perl):**
- Moo 2.005 - Lightweight OOP (replaces Moose)
- namespace::clean 0.27 - Exports cleanup
- JSON::XS 4.0 - Fast JSON encoding/decoding
- HTTP::Tiny - HTTP client for APIs (ClickHouse, Telegram, Slack, Webhook, License server)
- Mojolicious 9.0 - Web server and routing

**Critical - Security & Auth:**
- Crypt::Eksblowfish::Bcrypt 0.009 - Password hashing
- Crypt::JWT 0.035 - JWT RS256 license verification
- MIME::Base64 - Base64 encoding for auth headers
- Net::LDAP - LDAP/Active Directory authentication (optional)
- Net::SAML2 0.63 - SAML 2.0 SSO (optional)
- IO::Socket::SSL 2.0 - TLS for LDAP connections

**Data & Storage:**
- ClickHouse HTTP API (native HTTP client, no Perl driver)
- URI::Escape - URL encoding for ClickHouse queries
- Digest::MD5 - Cache key generation
- Time::Piece - Date/time operations
- File::Path, File::Spec - Filesystem operations

**Frontend (JavaScript):**
- Svelte 5.16 - UI framework
- Vite 6.0+ - Build and dev server
- ESLint 9.17, eslint-plugin-svelte 2.46 - Code linting
- Playwright 1.58+ - E2E testing

## Configuration

**Environment:**
- .env file (Docker Compose) - Runtime configuration
- `lib/Purl/Config.pm` - Configuration loader (ENV > File > Default priority)
- Configuration file: `/app/config/settings.json` (mounted volume in Docker)
- Priority order: Environment variables (highest) → Config file → Defaults

**Build:**
- Makefile - Local development targets (lint, test, build, docker)
- `web/vite.config.js` - Frontend bundling config
- `docker-compose.yml` - Service orchestration
- `.perlcriticrc` - Perl linting policy
- `web/eslint.config.js` - JavaScript linting rules

## Platform Requirements

**Development:**
- macOS or Linux
- Perl 5.24+ installed (via system or asdf/plenv)
- Node.js 18+ (for frontend dev/build)
- Docker & Docker Compose (for services)
- Make (standard GNU Make)

**Production:**
- Docker (containerized deployment)
- ClickHouse 25.11+ (Alpine image: `clickhouse/clickhouse-server:25.11-alpine`)
- Deployment target: Docker Compose on Linux VMs or Kubernetes (Helm chart available)
- Image: `ismoilovdev/purl:${PURL_IMAGE_TAG:-latest}`
  - `main` branch → `:latest` tag
  - `dev` branch → `:dev` tag
  - SHA tag for all pushes

---

*Stack analysis: 2026-03-10*
