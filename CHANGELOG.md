# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-01-11

### Added

- **Core Features**
  - Log aggregation dashboard with ClickHouse storage
  - KQL (Kibana Query Language) search syntax support
  - Real-time log streaming via WebSocket (Live Tail)
  - Time-based histogram visualization
  - Field statistics sidebar (level, service, host)
  - Saved searches functionality
  - Alert system with Telegram, Slack, and Webhook notifications

- **API**
  - REST API for log ingestion and querying
  - WebSocket endpoint for live log streaming
  - Health check and Prometheus metrics endpoints
  - API Key authentication
  - Rate limiting (1000 req/min per IP)

- **Security**
  - API Key based authentication
  - Sec-Fetch-Site header validation for web UI
  - XSS protection with HTML escaping
  - SQL injection prevention with parameterized queries
  - Input validation and sanitization
  - Graceful shutdown with buffer flush

- **Deployment**
  - Docker Compose setup for single server
  - Kubernetes manifests (Deployment, StatefulSet, DaemonSet)
  - Systemd service files for bare metal
  - Vector log collector configurations
  - GitHub Actions CI/CD for Docker image build

- **Frontend**
  - Svelte 5 dashboard
  - Dark theme UI
  - Responsive design
  - Log detail panel with JSON formatting
  - Search highlighting
  - Analytics page with metrics
  - Settings page for configuration

### Technical Stack

- **Backend**: Perl 5.38, Mojolicious
- **Storage**: ClickHouse (MergeTree, ZSTD, LowCardinality)
- **Frontend**: Svelte 5, Vite, Chart.js
- **Log Collection**: Vector
- **Deploy**: Docker, Kubernetes, Systemd

[1.0.0]: https://github.com/ismoilovdevml/purl/releases/tag/v1.0.0
