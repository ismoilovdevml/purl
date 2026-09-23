<script>
  import { onMount, onDestroy } from 'svelte';
  import Icon from './ui/Icon.svelte';
  import HealthBadge from './analytics/HealthBadge.svelte';
  import PerformanceCards from './analytics/PerformanceCards.svelte';
  import ResourceCards from './analytics/ResourceCards.svelte';
  import { refresh } from './ui/icons.js';
  import { formatBytes, formatNumber } from '../utils/format.js';
  import { success as toastSuccess, error as toastError } from '../stores/toast.js';
  import { api } from '../utils/api.js';

  // Raw: every poll replaces these wholesale; nothing mutates them in place.
  let stats = $state.raw(null);
  let metrics = $state.raw(null);
  let tableStats = $state.raw([]);
  let slowQueries = $state.raw([]);
  let loading = $state(true);
  let error = $state(null);
  let refreshInterval;
  let lastUpdated = $state(null);

  async function fetchAnalytics() {
    try {
      // Fire all four in parallel. Tables/queries are optional (may be
      // feature-gated or unavailable) so their failures are swallowed,
      // mirroring the previous `if (res.ok)` guards.
      const statsPromise = api.get('/stats');
      const metricsPromise = api.get('/metrics/json');
      const tablePromise = api.get('/analytics/tables').catch(() => null);
      const queriesPromise = api.get('/analytics/queries', { query: { limit: 5 } }).catch(() => null);

      stats = await statsPromise;
      metrics = await metricsPromise;

      const tData = await tablePromise;
      if (tData) {
        tableStats = tData.tables || [];
      }

      const qData = await queriesPromise;
      if (qData) {
        slowQueries = qData.queries || [];
      }

      lastUpdated = new Date();
      error = null;
    } catch (err) {
      error = err.message;
    } finally {
      loading = false;
    }
  }

  onMount(() => {
    fetchAnalytics();
    refreshInterval = setInterval(fetchAnalytics, 10000);
  });

  onDestroy(() => {
    if (refreshInterval) clearInterval(refreshInterval);
  });

  function formatTime(date) {
    if (!date) return '-';
    return date.toLocaleTimeString();
  }

  // Computed values from real metrics
  const requestsTotal = $derived(metrics?.requests?.total || 0);
  const errorsTotal = $derived(metrics?.requests?.errors || 0);
  const errorRate = $derived(requestsTotal > 0 ? ((errorsTotal / requestsTotal) * 100).toFixed(2) : '0.00');
  const cacheHitRate = $derived(metrics?.cache?.hit_rate || '0%');
  const avgQueryTime = $derived(metrics?.clickhouse?.avg_query_time || '0s');
  const totalStorage = $derived(tableStats.reduce((acc, t) => acc + (t.bytes || 0), 0));
  const uptimeHuman = $derived(metrics?.server?.uptime_human || '-');
  const uptimeSecs = $derived(metrics?.server?.uptime_secs || 0);

  // Request metrics
  const requestsPerSec = $derived(metrics?.requests?.per_second || '0');
  const p50Latency = $derived(metrics?.requests?.p50_latency || '0ms');
  const p95Latency = $derived(metrics?.requests?.p95_latency || '0ms');
  const p99Latency = $derived(metrics?.requests?.p99_latency || '0ms');
  const maxLatency = $derived(metrics?.requests?.max_latency || '0ms');
  const bytesIn = $derived(metrics?.requests?.bytes_in || 0);
  const bytesOut = $derived(metrics?.requests?.bytes_out || 0);

  // SLA (the weighted health score lives in HealthBadge)
  const slaCompliance = $derived(parseFloat(errorRate) < 1 ? 99.9 : (100 - parseFloat(errorRate)).toFixed(1));

  let clearingCache = $state(false);

  async function clearCache() {
    clearingCache = true;
    try {
      const data = await api.del('/cache');
      if (data.success) {
        toastSuccess(data.message || 'Cache cleared successfully');
        await fetchAnalytics();
      } else {
        toastError(data.message || 'Failed to clear cache');
      }
    } catch (err) {
      toastError('Failed to clear cache: ' + err.message);
    } finally {
      clearingCache = false;
    }
  }
</script>

<div class="analytics">
  <!-- Header -->
  <header>
    <div class="header-left">
      <h1>Analytics</h1>
      <HealthBadge
        {errorRate}
        {p95Latency}
        {p99Latency}
        {cacheHitRate}
        {uptimeSecs}
        {uptimeHuman}
        {requestsPerSec}
      />
    </div>
    <div class="header-right">
      <span class="updated">Updated: {formatTime(lastUpdated)}</span>
      <button class="refresh-btn" onclick={fetchAnalytics} disabled={loading} aria-label="Refresh">
        <Icon icon={refresh} size={14} spin={loading} />
      </button>
    </div>
  </header>

  {#if error}
    <div class="error-banner">{error}</div>
  {:else if loading && !stats}
    <div class="loading">
      <div class="spinner"></div>
    </div>
  {:else}
    <!-- Status Bar -->
    <div class="status-bar">
      <div class="status-item">
        <span class="dot green"></span>
        <span>System</span>
      </div>
      <div class="status-item">
        <span class="dot {parseFloat(errorRate) > 1 ? 'red' : 'green'}"></span>
        <span>Errors: {errorRate}%</span>
      </div>
      <div class="status-item">
        <span class="dot {cacheHitRate === '0%' ? 'yellow' : 'green'}"></span>
        <span>Cache: {cacheHitRate}</span>
      </div>
      <div class="status-item">
        <span class="dot green"></span>
        <span>ClickHouse</span>
      </div>
      <div class="status-item sla">
        <span>SLA: {slaCompliance}%</span>
      </div>
    </div>

    <!-- Main Grid - 6 columns -->
    <div class="main-grid">
      <div class="metric-card">
        <div class="metric-value">{formatNumber(stats?.total_logs)}</div>
        <div class="metric-label">Total Logs</div>
      </div>
      <div class="metric-card">
        <div class="metric-value">{formatBytes(totalStorage)}</div>
        <div class="metric-label">Storage</div>
      </div>
      <div class="metric-card">
        <div class="metric-value">{uptimeHuman}</div>
        <div class="metric-label">Uptime</div>
      </div>
      <div class="metric-card">
        <div class="metric-value">{formatNumber(requestsTotal)}</div>
        <div class="metric-label">Requests</div>
      </div>
      <div class="metric-card">
        <div class="metric-value">{avgQueryTime}</div>
        <div class="metric-label">Avg Response</div>
      </div>
      <div class="metric-card accent">
        <div class="metric-value">{errorRate}%</div>
        <div class="metric-label">Error Rate</div>
      </div>
    </div>

    <!-- Three Column Layout -->
    <PerformanceCards
      {metrics}
      {stats}
      {avgQueryTime}
      {cacheHitRate}
      {p50Latency}
      {p95Latency}
      {p99Latency}
      {maxLatency}
    />

    <ResourceCards
      {metrics}
      {tableStats}
      {slowQueries}
      {cacheHitRate}
      {requestsPerSec}
      {bytesIn}
      {bytesOut}
      {clearingCache}
      onclearcache={clearCache}
    />
  {/if}
</div>

<style>
  .analytics {
    padding: 16px 20px;
    overflow-y: auto;
    height: calc(100vh - 60px);
  }

  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 16px;
  }

  h1 {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .updated {
    font-size: 0.6875rem;
    color: #848d97;
  }

  .refresh-btn {
    padding: 6px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #c9d1d9;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .refresh-btn:hover { background: #30363d; }
  .refresh-btn:disabled { opacity: 0.6; }

  .error-banner {
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid #f85149;
    color: #f85149;
    padding: 8px 12px;
    border-radius: 6px;
    font-size: 0.8125rem;
  }

  .loading {
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 1;
    min-height: 200px;
  }

  .spinner {
    width: 20px;
    height: 20px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  /* Status Bar */
  .status-bar {
    display: flex;
    gap: 20px;
    padding: 8px 14px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    margin-bottom: 12px;
  }

  .status-item {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 0.75rem;
    color: #8b949e;
  }

  .status-item.sla {
    margin-left: auto;
    font-weight: 600;
    color: #3fb950;
  }

  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
  }

  .dot.green { background: #3fb950; }
  .dot.yellow { background: #d29922; }
  .dot.red { background: #f85149; }

  /* Main Grid */
  .main-grid {
    display: grid;
    grid-template-columns: repeat(6, 1fr);
    gap: 12px;
    margin-bottom: 12px;
  }

  .metric-card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 14px 16px;
  }

  .metric-card.accent {
    border-color: #238636;
  }

  .metric-value {
    font-size: 1.5rem;
    font-weight: 600;
    color: #f0f6fc;
    line-height: 1.2;
  }

  .metric-label {
    font-size: 0.6875rem;
    color: #8b949e;
    text-transform: uppercase;
    margin-top: 2px;
  }

  /* Responsive */
  @media (max-width: 1200px) {
    .main-grid {
      grid-template-columns: repeat(3, 1fr);
    }
  }

  @media (max-width: 800px) {
    .main-grid {
      grid-template-columns: repeat(2, 1fr);
    }
  }
</style>
