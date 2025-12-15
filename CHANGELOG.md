# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
