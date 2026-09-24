# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Ingest is durable by default in the Helm chart (2.2.2, new
  `purl.ingestDurable: true`) and in `docker-compose.yml` /
  `.env.example` (`PURL_INGEST_DURABLE=1`) (#126). In fast mode ClickHouse
  can reject an async-insert flush after Purl has already answered 2xx
  (seen live as code 241, memory limit exceeded), and those logs were lost
  with no error in Purl. Durable mode surfaces the failure so the batch is
  retried or the request answers 503 and the collector resends. Each flush
  now waits for ClickHouse to commit it. Set `purl.ingestDurable=false` or
  `PURL_INGEST_DURABLE=0` to keep the old behaviour.
- The chart's PrometheusRule adds `PurlIngestDropped`
  (`increase(purl_ingest_dropped_total[5m]) > 0`), which fires when Purl
  drops logs it had accepted because its ingest buffer is full.
- Log level detection in the Vector configs (Helm chart 2.2.1,
  `deploy/vector/vector.toml` for docker compose, and the agent that
  `install.sh -a` sets up) no longer matches a level word anywhere in a line
  (#111). A JSON `level` / `severity` / `lvl` / `log.level` field wins, then a
  level at the start of the line, then `level=` in logfmt lines, then an
  upper-case `ERROR` / `WARN` / `FATAL`, `[error]`, `<Error>` or similar
  marker in the first 120 characters. **Docker and agent users:** lines that
  only contain a bare "failed", "exception" or "err" (e.g. "request failed,
  retrying") are no longer ERROR but INFO, so ERROR counts and alerts based
  on them will drop.

### Fixed

- Helm chart 2.2.3: the Vector DaemonSet's journald source is now opt-in
  (`vector.journald.enabled`, default `false`) (#136). The default alpine
  Vector image has no `journalctl`, so the source failed on every node and
  collected nothing. When enabled, the chart uses the Vector debian image and
  mounts `/var/log/journal`, `/run/log/journal` and the host
  `/etc/machine-id` read-only.
- Helm chart 2.2.3: ClickHouse drops the system log tables that the small
  profile disables, plus their renamed `<name>_N` leftovers, on every start
  (`clickhouse.dropDisabledSystemLogs`, default `true`) (#139). ClickHouse
  never deletes an existing log table when the profile turns it off; one
  install kept ~570 MiB of them. `query_log`, `part_log` and the `purl`
  database are never touched. docker compose installs: run the one-off
  command in chart/README.md, "ClickHouse system log cleanup".

- ClickHouse small profile (chart 2.2.2 and `docker/clickhouse/config.xml`):
  `vertical_merge_algorithm_min_rows_to_activate` is now 1, so wide tables
  merge column by column. A Horizontal merge of a leftover 1531-column
  `system.metric_log` from a pre-profile install needed ~1 GiB, failed at the
  memory cap, retried every few seconds and made unrelated inserts fail with
  code 241 (memory limit exceeded). Under 1,100 rows/s for 10 minutes, code-241
  errors went from 1,955 to 0 and peak ClickHouse memory from 1,215 MiB to
  525 MiB.
- The Vector agent config written by `install.sh -a` did not compile (VRL
  rejected its `else` clauses), so the agent never started.
- The chart's Vector config aborted the remap (the event went out without
  service, level or meta) when a JSON `msg` was not a string.

## [1.3.0] - 2026-09-24

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
- `POST /api/ai/query` also returns `query`: the question's filter in
  search-bar syntax (issue #98). It is only included when the search parser
  accepts it, so it can be applied to the search bar as is.

### Changed

- **Helm chart repo moved** to GitHub Pages: `helm repo add purl
  https://ismoilovdevml.github.io/purl`. Each chart version is also a GitHub
  Release (`purl-<version>`). CI publishes it (`chart-release.yml`) when
  `chart/Chart.yaml`'s version changes on `main`, and only once the image
  named by `appVersion` is on Docker Hub. Chart versions 1.0.0 to 1.0.2 are
  carried over. `https://charts.purlogs.com` is frozen at 1.0.2; if you added
  it, run `helm repo remove purl` and add the new URL.
- Docker image base: Perl 5.42 (was 5.40) and Node 24 LTS for the web build
  (was Node 20, now end-of-life). CI builds the frontend on Node 24 too.
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

### Fixed

- Search matches non-ASCII text (Cyrillic, CJK, emoji, accented Latin); a
  search for `café` used to return nothing, and wider characters failed the
  request. Cached search results no longer lose their timestamp and `meta`.
- Updating a dashboard or pipeline no longer fails with a 500, and a field left
  out of an update keeps its value.
- Fast-mode ingest no longer loses accepted logs when ClickHouse is briefly
  unavailable. When the buffer is full, every ingest endpoint answers 503 with
  `Retry-After` so the sender retries; dropped rows are counted in
  `purl_ingest_dropped_total`. `PURL_INGEST_DURABLE=false` now means false.
- Time bounds with a zone offset, no zone, fractions, dates or epoch values are
  accepted and read as UTC; an offset timestamp used to reject the whole ingest
  batch. Server-side "now" is UTC.
- `/api/health/ready` no longer depends on ClickHouse, so an outage shows
  Purl's own error instead of the proxy's "no healthy upstream".
- A single failing or oversized query no longer opens the circuit breaker for
  every endpoint; only real outages do.
- Errors shown to users are short messages with a code and request id, never
  raw ClickHouse output or file paths.
- Query page results, the live-tail stream at high rates, the column picker
  near the bottom of the screen, and the settings pages on phones.
- Filter and facet by Kubernetes namespace, pod, container and cluster; log
  levels match case-insensitively.

### Performance

- ClickHouse no longer fills its uncompressed cache on every query, which ran
  a 5 GiB pod out of memory. Each query is capped at 256 MiB
  (`PURL_CLICKHOUSE_MAX_QUERY_MEMORY`), and log searches read only the rows
  they return.
- The Helm chart (2.2.0) and docker-compose ship a small ClickHouse profile:
  a 1536Mi limit and about 200 MiB idle, down from 4Gi and about 660 MiB.

### Security

- Logout now ends the session on the server. Previously a copy of the
  session cookie kept working after logout and its expiry slid forward on
  every request. Password changes, role changes and user deletion also end
  that user's sessions, and sessions have an absolute lifetime
  (`PURL_SESSION_MAX_AGE`, default 7 days). Everyone is signed out once on
  upgrade.
- **Logout signs you out on every device.** Revocation is per user, so logging
  out in one browser also ends that user's sessions in every other browser and
  device, and closes their open live-tail streams (WebSocket close code 4401,
  re-checked every 30 seconds).
- A request authenticated by an API key, bearer token or basic auth no longer
  picks up a role from a session cookie sent alongside it. It always has the
  viewer role, and the cookie is ignored (not validated, not renewed).
- Backup list, download, schedule and S3 config, and the LDAP and SSO
  settings reads, now require the admin role. They were previously readable
  by any authenticated caller, including ingest API keys, on licensed installs.
- AI endpoints now require a signed-in user.
- The audit log records events (issue #101). Nothing was ever written to it
  before, so Settings > Audit Logs was always empty. It now records logins,
  logouts, password changes, user management, settings changes, API key
  generation/revocation, alert changes and backups.
- A password change that races an admin password reset or a revocation is
  refused with 409 instead of undoing the reset.
- `POST /api/auth/logout` of a live session requires the CSRF token, like
  every other cookie-authenticated write.
- Basic auth: `admin:admin` is held to the forced password change (403 until
  it is changed), and an open live-tail stream authenticated with Basic auth is
  closed (4401) when that user's password changes or the user is deleted.

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

[Unreleased]: https://github.com/ismoilovdevml/purl/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/ismoilovdevml/purl/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/ismoilovdevml/purl/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ismoilovdevml/purl/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ismoilovdevml/purl/releases/tag/v1.0.0
