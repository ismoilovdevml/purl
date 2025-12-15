<script>
  import { onMount, onDestroy } from 'svelte';
  import { formatBytes, formatNumber, formatTime } from '../lib/utils.js';
  import { fetchStats, fetchMetrics, fetchTableAnalytics } from '../lib/api.js';

  let stats = null;
  let metrics = null;
  let tableStats = [];
  let loading = true;
  let error = null;
  let refreshInterval;
  let lastUpdated = null;

  async function fetchAnalytics() {
    try {
      const [statsData, metricsData, tablesData] = await Promise.all([
        fetchStats(),
        fetchMetrics(),
        fetchTableAnalytics().catch(() => ({ tables: [] })),
      ]);

      stats = statsData;
      metrics = metricsData;
      tableStats = tablesData.tables || [];

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

  // Note: formatBytes, formatNumber, formatTime are now in lib/utils.js

  $: errorRate = metrics?.clickhouse?.queries_total > 0
    ? ((metrics?.clickhouse?.errors_total || 0) / metrics.clickhouse.queries_total * 100).toFixed(2)
    : '0.00';

  $: cacheHitRate = metrics?.cache?.hit_rate || '0%';
  $: avgQueryTime = metrics?.clickhouse?.avg_query_time || '0s';
  $: totalStorage = tableStats.reduce((acc, t) => acc + (t.bytes || 0), 0);

  // Enterprise metrics
  $: requestsPerSec = metrics?.requests?.per_second || 0;
  $: p95Latency = metrics?.requests?.p95_latency || '0ms';
  $: p99Latency = metrics?.requests?.p99_latency || '0ms';
  $: slaCompliance = parseFloat(errorRate) < 1 ? 99.9 : (100 - parseFloat(errorRate)).toFixed(1);
  $: healthScore = calculateHealthScore();

  function calculateHealthScore() {
    let score = 100;
    if (parseFloat(errorRate) > 0) score -= parseFloat(errorRate) * 10;
    if (cacheHitRate === '0%') score -= 5;
    if (!metrics?.server?.uptime_human) score -= 10;
    return Math.max(0, Math.min(100, score)).toFixed(0);
  }

  function getHealthColor(score) {
    if (score >= 90) return '#3fb950';
    if (score >= 70) return '#d29922';
    return '#f85149';
  }
</script>

<div class="analytics">
  <!-- Header -->
  <header>
    <div class="header-left">
      <h1>Analytics</h1>
      <div class="health-badge" style="--health-color: {getHealthColor(healthScore)}">
        <span class="health-score">{healthScore}</span>
        <span class="health-label">Health</span>
      </div>
    </div>
    <div class="header-right">
      <span class="updated">Updated: {formatTime(lastUpdated)}</span>
      <button class="refresh-btn" on:click={fetchAnalytics} disabled={loading} aria-label="Refresh">
        <svg class:spinning={loading} width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M23 4v6h-6M1 20v-6h6"/>
          <path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
        </svg>
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
      <!-- Row 1: Key Metrics -->
      <div class="metric-card">
        <div class="metric-value">{formatNumber(stats?.total_logs)}</div>
        <div class="metric-label">Total Logs</div>
      </div>
      <div class="metric-card">
        <div class="metric-value">{formatBytes(totalStorage)}</div>
        <div class="metric-label">Storage</div>
      </div>
      <div class="metric-card">
        <div class="metric-value">{metrics?.server?.uptime_human || '-'}</div>
        <div class="metric-label">Uptime</div>
      </div>
      <div class="metric-card">
        <div class="metric-value">{formatNumber(metrics?.requests?.total)}</div>
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
    <div class="three-columns">
      <!-- Query Performance -->
      <div class="card">
        <h2>Query Performance</h2>
        <div class="mini-stats">
          <div class="mini-stat">
            <span class="label">Avg Time</span>
            <span class="value">{avgQueryTime}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Cache Hit</span>
            <span class="value">{cacheHitRate}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Total</span>
            <span class="value">{formatNumber(metrics?.clickhouse?.queries_total)}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Cached</span>
            <span class="value">{formatNumber(metrics?.clickhouse?.cached_queries)}</span>
          </div>
        </div>
      </div>

      <!-- Ingestion -->
      <div class="card">
        <h2>Ingestion <span class="live-badge">Live</span></h2>
        <div class="mini-stats">
          <div class="mini-stat">
            <span class="label">Buffer</span>
            <span class="value">{metrics?.clickhouse?.buffer_size || 0}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Inserts</span>
            <span class="value">{formatNumber(metrics?.clickhouse?.inserts_total)}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Written</span>
            <span class="value">{formatBytes(metrics?.clickhouse?.bytes_written)}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Rows</span>
            <span class="value">{formatNumber(metrics?.clickhouse?.rows_ingested)}</span>
          </div>
        </div>
      </div>

      <!-- Latency -->
      <div class="card">
        <h2>Latency</h2>
        <div class="mini-stats">
          <div class="mini-stat">
            <span class="label">P50</span>
            <span class="value">{avgQueryTime}</span>
          </div>
          <div class="mini-stat">
            <span class="label">P95</span>
            <span class="value">{p95Latency}</span>
          </div>
          <div class="mini-stat">
            <span class="label">P99</span>
            <span class="value">{p99Latency}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Max</span>
            <span class="value">{metrics?.requests?.max_latency || '0ms'}</span>
          </div>
        </div>
      </div>
    </div>

    <!-- Bottom Section: Tables + Cache + Throughput -->
    <div class="bottom-grid">
      <!-- Tables -->
      <div class="card tables-card">
        <h2>Tables <span class="count">{tableStats.length}</span></h2>
        <div class="tables-list">
          {#each tableStats as t}
            <div class="table-row">
              <span class="table-name">{t.table}</span>
              <span class="table-info">{formatNumber(t.rows)} rows</span>
              <span class="table-size">{formatBytes(t.bytes)}</span>
            </div>
          {/each}
        </div>
      </div>

      <!-- Cache -->
      <div class="card">
        <h2>Cache</h2>
        <div class="cache-grid">
          <div class="cache-item">
            <span class="cache-value">{cacheHitRate}</span>
            <span class="cache-label">Hit Rate</span>
          </div>
          <div class="cache-item">
            <span class="cache-value">{metrics?.cache?.entries || 0}</span>
            <span class="cache-label">Entries</span>
          </div>
          <div class="cache-item">
            <span class="cache-value">{metrics?.cache?.ttl || '60s'}</span>
            <span class="cache-label">TTL</span>
          </div>
        </div>
      </div>

      <!-- Throughput -->
      <div class="card">
        <h2>Throughput</h2>
        <div class="cache-grid">
          <div class="cache-item">
            <span class="cache-value">{requestsPerSec}/s</span>
            <span class="cache-label">Req/sec</span>
          </div>
          <div class="cache-item">
            <span class="cache-value">{formatBytes(metrics?.requests?.bytes_in || 0)}</span>
            <span class="cache-label">In</span>
          </div>
          <div class="cache-item">
            <span class="cache-value">{formatBytes(metrics?.requests?.bytes_out || 0)}</span>
            <span class="cache-label">Out</span>
          </div>
        </div>
      </div>
    </div>
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

  .health-badge {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 12px;
    background: rgba(63, 185, 80, 0.1);
    border: 1px solid var(--health-color);
    border-radius: 20px;
  }

  .health-score {
    font-size: 0.875rem;
    font-weight: 700;
    color: var(--health-color);
  }

  .health-label {
    font-size: 0.6875rem;
    color: #8b949e;
    text-transform: uppercase;
  }

  h2 {
    font-size: 0.75rem;
    font-weight: 600;
    color: #8b949e;
    margin: 0 0 10px 0;
    display: flex;
    align-items: center;
    gap: 8px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .updated {
    font-size: 0.6875rem;
    color: #6e7681;
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
  .refresh-btn svg.spinning { animation: spin 1s linear infinite; }

  @keyframes spin { to { transform: rotate(360deg); } }

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

  /* Main Grid - 6 columns */
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

  /* Three Columns */
  .three-columns {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
    margin-bottom: 12px;
  }

  .card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 14px 16px;
  }

  .mini-stats {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
  }

  .mini-stat {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .mini-stat .label {
    font-size: 0.75rem;
    color: #8b949e;
  }

  .mini-stat .value {
    font-size: 0.875rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .live-badge {
    background: #238636;
    color: #fff;
    font-size: 0.5625rem;
    padding: 2px 6px;
    border-radius: 8px;
    font-weight: 500;
  }

  /* Bottom Grid */
  .bottom-grid {
    display: grid;
    grid-template-columns: 2fr 1fr 1fr;
    gap: 12px;
  }

  .tables-card {
    overflow: hidden;
  }

  .count {
    background: #21262d;
    color: #8b949e;
    font-size: 0.625rem;
    padding: 2px 6px;
    border-radius: 8px;
  }

  .tables-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .table-row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 12px;
    background: #0d1117;
    border-radius: 6px;
  }

  .table-name {
    color: #58a6ff;
    font-family: "SFMono-Regular", Consolas, monospace;
    font-size: 0.8125rem;
    font-weight: 500;
    flex: 1;
  }

  .table-info {
    font-size: 0.75rem;
    color: #8b949e;
  }

  .table-size {
    font-size: 0.75rem;
    color: #6e7681;
    min-width: 70px;
    text-align: right;
  }

  /* Cache Grid */
  .cache-grid {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .cache-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .cache-value {
    font-size: 1.125rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .cache-label {
    font-size: 0.6875rem;
    color: #6e7681;
    text-transform: uppercase;
  }

  /* Responsive */
  @media (max-width: 1200px) {
    .main-grid {
      grid-template-columns: repeat(3, 1fr);
    }
    .bottom-grid {
      grid-template-columns: 1fr 1fr;
    }
  }

  @media (max-width: 800px) {
    .main-grid {
      grid-template-columns: repeat(2, 1fr);
    }
    .three-columns {
      grid-template-columns: 1fr;
    }
    .bottom-grid {
      grid-template-columns: 1fr;
    }
  }
</style>
