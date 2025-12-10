<script>
  import { onMount, onDestroy } from 'svelte';

  let stats = null;
  let clickhouseMetrics = null;
  let queryStats = [];
  let tableStats = [];
  let loading = true;
  let error = null;
  let refreshInterval;

  const API_BASE = '/api';

  async function fetchAnalytics() {
    try {
      const [statsRes, metricsRes, queryRes, tableRes] = await Promise.all([
        fetch(`${API_BASE}/stats`),
        fetch(`${API_BASE}/metrics/json`),
        fetch(`${API_BASE}/analytics/queries`),
        fetch(`${API_BASE}/analytics/tables`)
      ]);

      stats = await statsRes.json();
      clickhouseMetrics = await metricsRes.json();

      if (queryRes.ok) {
        const qData = await queryRes.json();
        queryStats = qData.queries || [];
      }

      if (tableRes.ok) {
        const tData = await tableRes.json();
        tableStats = tData.tables || [];
      }

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

  function formatBytes(bytes) {
    if (!bytes) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  function formatNumber(num) {
    if (!num) return '0';
    return num.toLocaleString();
  }

  function formatDuration(ms) {
    if (!ms) return '0ms';
    if (ms < 1000) return ms.toFixed(0) + 'ms';
    return (ms / 1000).toFixed(2) + 's';
  }
</script>

<div class="analytics-page">
  <header class="page-header">
    <h1>
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M3 3v18h18"/>
        <path d="M18 9l-5-6-4 8-3-2"/>
      </svg>
      Analytics
    </h1>
    <button class="refresh-btn" on:click={fetchAnalytics} disabled={loading}>
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class:spinning={loading}>
        <path d="M23 4v6h-6M1 20v-6h6"/>
        <path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
      </svg>
      Refresh
    </button>
  </header>

  {#if error}
    <div class="error-banner">{error}</div>
  {/if}

  {#if loading && !stats}
    <div class="loading">Loading analytics...</div>
  {:else}
    <!-- Overview Cards -->
    <section class="stats-grid">
      <div class="stat-card">
        <div class="stat-icon blue">
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
            <path d="M14 2v6h6M16 13H8M16 17H8M10 9H8"/>
          </svg>
        </div>
        <div class="stat-content">
          <span class="stat-label">Total Logs</span>
          <span class="stat-value">{formatNumber(stats?.total_logs)}</span>
        </div>
      </div>

      <div class="stat-card">
        <div class="stat-icon green">
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="2" y="2" width="20" height="8" rx="2"/>
            <rect x="2" y="14" width="20" height="8" rx="2"/>
            <line x1="6" y1="6" x2="6.01" y2="6"/>
            <line x1="6" y1="18" x2="6.01" y2="18"/>
          </svg>
        </div>
        <div class="stat-content">
          <span class="stat-label">Database Size</span>
          <span class="stat-value">{stats?.db_size_mb || 0} MB</span>
        </div>
      </div>

      <div class="stat-card">
        <div class="stat-icon purple">
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10"/>
            <polyline points="12,6 12,12 16,14"/>
          </svg>
        </div>
        <div class="stat-content">
          <span class="stat-label">Uptime</span>
          <span class="stat-value">{clickhouseMetrics?.server?.uptime || '-'}</span>
        </div>
      </div>

      <div class="stat-card">
        <div class="stat-icon orange">
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
          </svg>
        </div>
        <div class="stat-content">
          <span class="stat-label">Requests/min</span>
          <span class="stat-value">{clickhouseMetrics?.requests?.per_minute || 0}</span>
        </div>
      </div>
    </section>

    <!-- ClickHouse Metrics -->
    <section class="metrics-section">
      <h2>ClickHouse Performance</h2>
      <div class="metrics-grid">
        <div class="metric-card">
          <h3>Cache</h3>
          <div class="metric-row">
            <span>Hit Rate</span>
            <span class="value">{clickhouseMetrics?.cache?.hit_rate || '0%'}</span>
          </div>
          <div class="metric-row">
            <span>Size</span>
            <span class="value">{clickhouseMetrics?.cache?.size || 0} entries</span>
          </div>
        </div>

        <div class="metric-card">
          <h3>Queries</h3>
          <div class="metric-row">
            <span>Total</span>
            <span class="value">{formatNumber(clickhouseMetrics?.clickhouse?.queries_total)}</span>
          </div>
          <div class="metric-row">
            <span>Avg Time</span>
            <span class="value">{clickhouseMetrics?.clickhouse?.avg_query_time || '-'}</span>
          </div>
          <div class="metric-row">
            <span>Errors</span>
            <span class="value error">{formatNumber(clickhouseMetrics?.clickhouse?.errors_total)}</span>
          </div>
        </div>

        <div class="metric-card">
          <h3>Ingestion</h3>
          <div class="metric-row">
            <span>Total Inserted</span>
            <span class="value">{formatNumber(clickhouseMetrics?.ingestion?.total)}</span>
          </div>
          <div class="metric-row">
            <span>Bytes</span>
            <span class="value">{formatBytes(clickhouseMetrics?.clickhouse?.bytes_inserted)}</span>
          </div>
          <div class="metric-row">
            <span>Buffer</span>
            <span class="value">{clickhouseMetrics?.clickhouse?.buffer_size || 0}</span>
          </div>
        </div>

        <div class="metric-card">
          <h3>Storage</h3>
          <div class="metric-row">
            <span>Total Rows</span>
            <span class="value">{formatNumber(stats?.total_rows)}</span>
          </div>
          <div class="metric-row">
            <span>Oldest Log</span>
            <span class="value small">{stats?.oldest_log || '-'}</span>
          </div>
          <div class="metric-row">
            <span>Newest Log</span>
            <span class="value small">{stats?.newest_log || '-'}</span>
          </div>
        </div>
      </div>
    </section>

    <!-- Table Statistics -->
    {#if tableStats.length > 0}
      <section class="table-section">
        <h2>Table Statistics</h2>
        <table class="data-table">
          <thead>
            <tr>
              <th>Table</th>
              <th>Rows</th>
              <th>Size</th>
              <th>Partitions</th>
              <th>Avg Row Size</th>
            </tr>
          </thead>
          <tbody>
            {#each tableStats as t}
              <tr>
                <td class="table-name">{t.table}</td>
                <td>{formatNumber(t.rows)}</td>
                <td>{formatBytes(t.bytes)}</td>
                <td>{t.partitions || '-'}</td>
                <td>{t.rows > 0 ? formatBytes(t.bytes / t.rows) : '-'}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </section>
    {/if}

    <!-- Recent Queries -->
    {#if queryStats.length > 0}
      <section class="table-section">
        <h2>Recent Slow Queries</h2>
        <table class="data-table">
          <thead>
            <tr>
              <th>Query</th>
              <th>Duration</th>
              <th>Read Rows</th>
              <th>Memory</th>
            </tr>
          </thead>
          <tbody>
            {#each queryStats as q}
              <tr>
                <td class="query-text">{q.query?.substring(0, 100)}...</td>
                <td>{formatDuration(q.duration_ms)}</td>
                <td>{formatNumber(q.read_rows)}</td>
                <td>{formatBytes(q.memory_usage)}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </section>
    {/if}
  {/if}
</div>

<style>
  .analytics-page {
    padding: 20px;
    max-width: 1400px;
    margin: 0 auto;
  }

  .page-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 24px;
  }

  .page-header h1 {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 1.5rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .refresh-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 0.875rem;
  }

  .refresh-btn:hover {
    background: #30363d;
  }

  .refresh-btn:disabled {
    opacity: 0.6;
  }

  .spinning {
    animation: spin 1s linear infinite;
  }

  @keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }

  .error-banner {
    background: #f8514926;
    border: 1px solid #f85149;
    color: #f85149;
    padding: 12px 16px;
    border-radius: 6px;
    margin-bottom: 20px;
  }

  .loading {
    text-align: center;
    padding: 60px;
    color: #8b949e;
  }

  /* Stats Grid */
  .stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 16px;
    margin-bottom: 24px;
  }

  .stat-card {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 20px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
  }

  .stat-icon {
    width: 48px;
    height: 48px;
    border-radius: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .stat-icon.blue { background: #388bfd26; color: #58a6ff; }
  .stat-icon.green { background: #3fb95026; color: #3fb950; }
  .stat-icon.purple { background: #a371f726; color: #a371f7; }
  .stat-icon.orange { background: #d2992226; color: #d29922; }

  .stat-content {
    display: flex;
    flex-direction: column;
  }

  .stat-label {
    font-size: 0.75rem;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .stat-value {
    font-size: 1.5rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  /* Metrics Section */
  .metrics-section, .table-section {
    margin-bottom: 24px;
  }

  .metrics-section h2, .table-section h2 {
    font-size: 1rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0 0 16px 0;
  }

  .metrics-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    gap: 16px;
  }

  .metric-card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 16px;
  }

  .metric-card h3 {
    font-size: 0.875rem;
    font-weight: 600;
    color: #8b949e;
    margin: 0 0 12px 0;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .metric-row {
    display: flex;
    justify-content: space-between;
    padding: 8px 0;
    border-bottom: 1px solid #21262d;
    font-size: 0.875rem;
  }

  .metric-row:last-child {
    border-bottom: none;
  }

  .metric-row span:first-child {
    color: #8b949e;
  }

  .metric-row .value {
    color: #f0f6fc;
    font-weight: 500;
    font-family: 'SF Mono', Monaco, monospace;
  }

  .metric-row .value.error {
    color: #f85149;
  }

  .metric-row .value.small {
    font-size: 0.75rem;
  }

  /* Data Table */
  .data-table {
    width: 100%;
    border-collapse: collapse;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
  }

  .data-table th,
  .data-table td {
    padding: 12px 16px;
    text-align: left;
    border-bottom: 1px solid #21262d;
  }

  .data-table th {
    background: #0d1117;
    font-size: 0.75rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .data-table td {
    font-size: 0.875rem;
    color: #c9d1d9;
  }

  .data-table tbody tr:hover {
    background: #1c2128;
  }

  .table-name {
    font-family: 'SF Mono', Monaco, monospace;
    color: #58a6ff;
  }

  .query-text {
    font-family: 'SF Mono', Monaco, monospace;
    font-size: 0.75rem;
    color: #8b949e;
    max-width: 400px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
