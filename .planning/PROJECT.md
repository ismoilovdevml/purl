# Purl — Quality & Completeness Milestone

## What This Is

Self-hosted log aggregation platform with Perl/Mojolicious backend, Svelte 5 frontend, and ClickHouse storage. This milestone focuses on hardening the existing codebase: fixing backend bugs, deep refactoring for production readiness, building missing UI for all backend features, and achieving comprehensive test coverage.

## Core Value

Every backend feature has a working UI, every code path is tested, and the system is production-ready with no known bugs.

## Requirements

### Validated

- ✓ Log ingestion via REST API with API key auth — existing
- ✓ Log search with query syntax and time ranges — existing
- ✓ WebSocket live tail — existing
- ✓ Alert rules with Telegram/Slack/Webhook delivery — existing
- ✓ Pattern detection (message template hashing) — existing
- ✓ Dashboard widgets and layout — existing
- ✓ Session-based auth with login/logout — existing
- ✓ JWT RS256 license verification and feature gating — existing
- ✓ LDAP/SAML enterprise auth — existing
- ✓ Multi-tenancy namespace scoping — existing
- ✓ S3 backup management — existing
- ✓ Pipeline processing — existing
- ✓ Agent registration and heartbeat — existing
- ✓ Saved searches — existing
- ✓ Settings management (database, notifications, users) — existing
- ✓ Rate limiting — existing
- ✓ CSRF protection — existing

### Active

- [ ] Backend bug audit and fixes (code smells, edge cases, error handling)
- [ ] Deep refactoring (separation of concerns, DRY, modular architecture)
- [ ] UI for all backend endpoints that lack frontend coverage
- [ ] Full test coverage (unit + integration + API endpoint, all edge cases)
- [ ] Production hardening (security, performance, error handling)

### Out of Scope

- New features beyond existing backend capabilities — this milestone is about quality, not new functionality
- Mobile app — web-first
- Migration to different database — ClickHouse is the chosen storage
- Frontend framework change — Svelte 5 stays

## Context

- Brownfield project with 25+ controllers, complex middleware pipeline
- Existing codebase map available at `.planning/codebase/`
- Some backend features (settings categories, alert management, user management) have endpoints but incomplete or missing UI
- Test coverage needs expansion — currently basic TAP tests exist
- Recent commits fixed 12+ backend bugs, but systematic audit needed
- Docker-based deployment with CI/CD via GitHub Actions

## Constraints

- **Tech stack**: Perl 5.40/Mojolicious backend, Svelte 5/Vite frontend, ClickHouse storage — no changes
- **Compatibility**: Must not break existing API contracts (agents, external integrations)
- **CI/CD**: All changes must pass `make preflight` (lint + test + build)
- **Auth**: Existing auth mechanisms (API keys, sessions, JWT, LDAP, SAML) must remain intact

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Deep refactor over minimal fixes | User wants production-ready quality, not patches | — Pending |
| Parallel work streams | Bug fix + UI + tests can proceed simultaneously | — Pending |
| Full test coverage target | Unit + integration + API endpoint tests for all edge cases | — Pending |

---
*Last updated: 2026-03-10 after initialization*
