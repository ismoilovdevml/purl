# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed

- Removed commercial licensing: every feature is available without a license
  key; no license heartbeat. The license settings are gone from the Helm
  chart (`purl.license`, chart 2.1.0), `docker-compose.yml`, `.env.example`,
  `install.sh` and the dev deploy workflow.
- **BREAKING** API: `GET /api/license` and `PUT /api/settings/license`.
- **BREAKING** `deploy/kubernetes/` raw manifests and their `install.sh` /
  `uninstall.sh` (issue #41). They duplicated the Helm chart without any of its
  hardening. The chart is the only supported Kubernetes path — see the
  migration steps in README.md.

### Added

- `GET /api/auth/sso/status` returns `{enabled}`.
- `GET /api/auth/me` includes `k8s_mode`.
- Per-user rate limit on AI endpoints (`PURL_AI_RATE_LIMIT`, default 20 per
  minute); over the limit returns 429.

### Changed

- `GET /api/agents` no longer returns `limit`.
- Unknown `/api/*` routes return a JSON 404 instead of the dashboard HTML.
- **BREAKING** The chart no longer invents `PURL_CLICKHOUSE_PASSWORD`,
  `PURL_SESSION_SECRET` or `PURL_API_KEYS` by default (issue #22). Generation
  relied on `lookup`, which is always empty without cluster access, so every
  `helm template` / Argo CD sync minted a new credential and rolled both
  workloads. The render now fails instead. Set `purl.autoGenerateSecrets=true`
  for an interactive `helm install`, or supply `purl.existingSecret` / explicit
  values under GitOps.
- kube-apiserver audit policy and webhook config moved from
  `deploy/kubernetes/` to `deploy/k8s-audit/`. They configure the apiserver,
  not Purl, so they were never part of the chart.

### Security

- Logout now ends the session on the server. Previously a copy of the
  session cookie kept working after logout and its expiry slid forward on
  every request. Password changes, role changes and user deletion also end
  that user's sessions, and sessions have an absolute lifetime
  (`PURL_SESSION_MAX_AGE`, default 7 days). Everyone is signed out once on
  upgrade.
- Backup list, download, schedule and S3 config, and the LDAP and SSO
  settings reads, now require the admin role. They were previously readable
  by any authenticated caller, including ingest API keys, on licensed installs.
- AI endpoints now require a signed-in user.

## [1.2.0] - 2025-12-15

### Added

- Kubernetes one-line install script (`deploy/kubernetes/install.sh`)
- Kubernetes uninstall script (`deploy/kubernetes/uninstall.sh`)
- K8s metadata sidebar (namespace, pod, node filters)
- Copy-to-clipboard with visual feedback on log details
- Meta field support in KQL queries (`meta.namespace:value`, `meta.pod:*`)

### Changed

- Vector VRL config: improved JSON log parsing with `exists()` checks
- README: simplified K8s installation instructions
- Log detail rows now clickable for quick copy
- Reduced K8s deployment replicas for resource optimization

### Fixed

- KQL parser regex to support dot notation (`meta.namespace`)
- Vector JSON message extraction (was showing raw JSON)
- Build output gitignore (web/public/index.html)

## [1.1.0] - 2025-12-13

### Added

- Gzip decompression for Vector agent logs
- Analytics page with Chart.js visualizations
- Log pattern analysis and trace/request ID filtering
- Custom time range picker with presets
- CSRF protection and password hashing
- Portable install script (macOS/Linux support)
- Dynamic hostname configuration (VECTOR_HOSTNAME)
- Conditional journald source for minimal hosts

### Changed

- Consolidated CI/CD into single workflow
- Renamed Server `new` to `create` (Mojolicious compatibility)
- Simplified README for better UX
- Cleaned up unused config files and duplicates

### Fixed

- Vector noise filtering (ClickHouse stack traces, internal logs)
- GitHub Actions dependency installation
- ESLint quote style consistency
- `sed -i` and `hostname -I` portability issues

## [1.0.0] - 2025-01-11

### Added

- Log aggregation dashboard with ClickHouse storage
- KQL search syntax support
- Real-time log streaming via WebSocket
- Alert system (Telegram, Slack, Webhook)
- API Key authentication and rate limiting
- Docker, Kubernetes, Systemd deployment options
- Svelte 5 dark theme dashboard
- Vector log collector configurations

[1.2.0]: https://github.com/ismoilovdevml/purl/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ismoilovdevml/purl/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ismoilovdevml/purl/releases/tag/v1.0.0
