<!--
  AboutSettings Component
  About page with system info

  Usage:
  <AboutSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';
  import Button from '../ui/Button.svelte';

  const API_BASE = '/api';
  let systemInfo = null;
  let metricsInfo = null;

  onMount(() => {
    fetchSystemInfo();
    fetchMetrics();
  });

  async function fetchSystemInfo() {
    try {
      const res = await fetch(`${API_BASE}/health`);
      if (res.ok) {
        systemInfo = await res.json();
      }
    } catch {
      // Ignore
    }
  }

  async function fetchMetrics() {
    try {
      const res = await fetch(`${API_BASE}/metrics/json`);
      if (res.ok) {
        metricsInfo = await res.json();
      }
    } catch {
      // Ignore
    }
  }

  function formatUptime(seconds) {
    if (!seconds) return '0s';
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    const parts = [];
    if (days > 0) parts.push(`${days}d`);
    if (hours > 0) parts.push(`${hours}h`);
    if (mins > 0) parts.push(`${mins}m`);
    return parts.join(' ') || '< 1m';
  }

  function formatBytes(bytes) {
    if (!bytes) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    while (bytes >= 1024 && i < units.length - 1) {
      bytes /= 1024;
      i++;
    }
    return `${bytes.toFixed(1)} ${units[i]}`;
  }

  function formatNumber(num) {
    if (!num) return '0';
    return num.toLocaleString();
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>About Purl</h3>
    <p>Log aggregation and analysis platform</p>
  </div>

  <div class="about-grid">
    <Card padding="lg" class="about-card main-card">
      <div class="about-logo">
        <svg width="72" height="72" viewBox="0 0 32 32">
          <circle cx="16" cy="16" r="14" fill="none" stroke="#58a6ff" stroke-width="2"/>
          <path d="M10 12 L22 12 M10 16 L22 16 M10 20 L18 20" stroke="#58a6ff" stroke-width="2" stroke-linecap="round"/>
        </svg>
      </div>

      <h2>Purl</h2>
      <p class="about-tagline">Fast, Modern Log Aggregation</p>
      <p class="about-version">v{systemInfo?.version || '...'}</p>

      <div class="tech-stack">
        <Badge variant="default" pill>Perl</Badge>
        <Badge variant="default" pill>ClickHouse</Badge>
        <Badge variant="default" pill>Svelte</Badge>
        <Badge variant="default" pill>Vector</Badge>
      </div>

      <div class="about-links">
        <Button variant="default" on:click={() => window.open('https://github.com/ismoilovdevml/purl', '_blank')}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
            <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
          </svg>
          GitHub
        </Button>
      </div>
    </Card>

    <div class="info-cards">
      <Card padding="md" class="info-card">
        <div class="info-card-header">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
          </svg>
          <h4>System Status</h4>
        </div>
        <div class="info-card-content">
          <div class="info-row">
            <span>Status</span>
            <Badge variant={systemInfo?.status === 'ok' ? 'success' : 'error'} size="sm">
              {systemInfo?.status?.toUpperCase() || '...'}
            </Badge>
          </div>
          <div class="info-row">
            <span>ClickHouse</span>
            <span class="info-value connected">{systemInfo?.clickhouse || '...'}</span>
          </div>
          <div class="info-row">
            <span>Uptime</span>
            <span class="info-value">{formatUptime(systemInfo?.uptime_secs)}</span>
          </div>
        </div>
      </Card>

      <Card padding="md" class="info-card">
        <div class="info-card-header">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <ellipse cx="12" cy="5" rx="9" ry="3"/>
            <path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/>
            <path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/>
          </svg>
          <h4>Storage</h4>
        </div>
        <div class="info-card-content">
          <div class="info-row">
            <span>Total Logs</span>
            <span class="info-value">{formatNumber(metricsInfo?.logs_stored)}</span>
          </div>
          <div class="info-row">
            <span>Database Size</span>
            <span class="info-value">{formatBytes(metricsInfo?.db_size_bytes)}</span>
          </div>
          <div class="info-row">
            <span>Cache Entries</span>
            <span class="info-value">{formatNumber(metricsInfo?.cache_size)}</span>
          </div>
        </div>
      </Card>

      <Card padding="md" class="info-card">
        <div class="info-card-header">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M18 20V10M12 20V4M6 20v-6"/>
          </svg>
          <h4>Performance</h4>
        </div>
        <div class="info-card-content">
          <div class="info-row">
            <span>Total Requests</span>
            <span class="info-value">{formatNumber(metricsInfo?.http_requests_total)}</span>
          </div>
          <div class="info-row">
            <span>Avg Response</span>
            <span class="info-value">{metricsInfo?.avg_response_ms?.toFixed(1) || '0'}ms</span>
          </div>
          <div class="info-row">
            <span>Prometheus</span>
            <a href="/api/metrics" target="_blank" class="info-link">/api/metrics</a>
          </div>
        </div>
      </Card>
    </div>
  </div>
</section>

<style>
  .settings-section {
    max-width: 900px;
  }

  .section-header {
    margin-bottom: 24px;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  .about-grid {
    display: grid;
    grid-template-columns: 280px 1fr;
    gap: 20px;
  }

  @media (max-width: 768px) {
    .about-grid {
      grid-template-columns: 1fr;
    }
  }

  :global(.main-card) {
    text-align: center;
  }

  .about-logo {
    margin-bottom: 16px;
  }

  :global(.main-card) h2 {
    margin: 0;
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--text-primary, #f0f6fc);
  }

  .about-tagline {
    margin: 4px 0 0;
    font-size: 0.9375rem;
    color: var(--text-secondary, #8b949e);
  }

  .about-version {
    margin: 8px 0 20px;
    font-size: 0.8125rem;
    color: var(--text-muted, #6e7681);
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
  }

  .tech-stack {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 8px;
    margin-bottom: 24px;
  }

  .about-links {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 10px;
  }

  .info-cards {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  :global(.info-card) {
    background: var(--bg-secondary, #161b22) !important;
  }

  .info-card-header {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 12px;
    padding-bottom: 10px;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .info-card-header svg {
    color: var(--color-primary, #58a6ff);
  }

  .info-card-header h4 {
    margin: 0;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
  }

  .info-card-content {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .info-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 0.8125rem;
  }

  .info-row span:first-child {
    color: var(--text-secondary, #8b949e);
  }

  .info-value {
    color: var(--text-primary, #f0f6fc);
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.8125rem;
  }

  .info-value.connected {
    color: var(--color-success, #3fb950);
  }

  .info-link {
    color: var(--color-primary, #58a6ff);
    text-decoration: none;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
  }

  .info-link:hover {
    text-decoration: underline;
  }
</style>
