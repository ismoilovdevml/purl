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
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import Icon from '../ui/Icon.svelte';
  import { activity, barChart, database, logo } from '../ui/icons.js';
  import { api } from '../../utils/api.js';
  import { formatBytes, formatNumber } from '../../utils/format.js';

  let systemInfo = $state(null);
  let metricsInfo = $state(null);
  let loadingInfo = $state(true);

  onMount(async () => {
    await Promise.all([fetchSystemInfo(), fetchMetrics()]);
    loadingInfo = false;
  });

  // Both panels are informational: a failure leaves the value null and the
  // markup falls back to its own placeholder, exactly as before. Going through
  // `api` adds the centralized 401 session-expiry handling these calls lacked.
  async function fetchSystemInfo() {
    try {
      systemInfo = await api.get('/health');
    } catch {
      // Ignore
    }
  }

  async function fetchMetrics() {
    try {
      metricsInfo = await api.get('/metrics/json');
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

</script>

<section class="settings-section">
  <div class="section-header">
    <h3>About Purl</h3>
    <p>Log aggregation and analysis platform</p>
  </div>

  {#if loadingInfo}
    <LoadingSpinner centered label="Loading system info..." />
  {:else}
  <div class="about-grid">
    <Card padding="lg" class="about-card main-card">
      <div class="about-logo">
        <Icon icon={logo} size={72} color="#58a6ff" />
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

    </Card>

    <div class="info-cards">
      <Card padding="md" class="info-card">
        <div class="info-card-header">
          <Icon icon={activity} size={20} />
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
          <Icon icon={database} size={20} />
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
          <Icon icon={barChart} size={20} />
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
  {/if}
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
    color: var(--text-bright);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary);
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
    color: var(--text-bright);
  }

  .about-tagline {
    margin: 4px 0 0;
    font-size: 0.9375rem;
    color: var(--text-secondary);
  }

  .about-version {
    margin: 8px 0 20px;
    font-size: 0.8125rem;
    color: var(--text-muted);
    font-family: var(--font-mono);
  }

  .tech-stack {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 8px;
    margin-bottom: 24px;
  }

  .info-cards {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  :global(.info-card) {
    background: var(--bg-secondary) !important;
  }

  .info-card-header {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 12px;
    padding-bottom: 10px;
    border-bottom: 1px solid var(--border-muted);
  }

  .info-card-header :global(svg) {
    color: var(--color-primary);
  }

  .info-card-header h4 {
    margin: 0;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-bright);
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
    color: var(--text-secondary);
  }

  .info-value {
    color: var(--text-bright);
    font-family: var(--font-mono);
    font-size: 0.8125rem;
  }

  .info-value.connected {
    color: var(--color-success);
  }

  .info-link {
    color: var(--color-primary);
    text-decoration: none;
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }

  .info-link:hover {
    text-decoration: underline;
  }
</style>
