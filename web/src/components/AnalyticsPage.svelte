<script>
  import { onMount, onDestroy } from 'svelte';

  let stats = null;
  let clickhouseMetrics = null;
  let queryStats = [];
  let tableStats = [];
  let loading = true;
  let error = null;
  let refreshInterval;
  let selectedTab = 'overview';
  let timeRange = '1h';

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
    if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
    if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
    return num.toLocaleString();
  }

  function formatDuration(ms) {
    if (!ms) return '0ms';
    if (ms < 1000) return ms.toFixed(0) + 'ms';
    if (ms < 60000) return (ms / 1000).toFixed(2) + 's';
    return (ms / 60000).toFixed(1) + 'm';
  }

  function getUptimeStatus() {
    const uptime = clickhouseMetrics?.server?.uptime_secs || 0;
    if (uptime < 300) return 'warning';
    return 'healthy';
  }

  $: errorRate = clickhouseMetrics?.clickhouse?.queries_total > 0
    ? ((clickhouseMetrics?.clickhouse?.errors_total || 0) / clickhouseMetrics.clickhouse.queries_total * 100).toFixed(2)
    : 0;

  $: cacheHitRate = parseFloat(clickhouseMetrics?.cache?.hit_rate || '0%') || 0;

  $: avgQueryTime = parseFloat(clickhouseMetrics?.clickhouse?.avg_query_time || '0') || 0;
</script>

<div class="analytics-page">
  <!-- Compact Header -->
  <header class="header">
    <div class="header-left">
      <h1>Analytics</h1>
      <div class="tabs">
        <button class:active={selectedTab === 'overview'} on:click={() => selectedTab = 'overview'}>Overview</button>
        <button class:active={selectedTab === 'performance'} on:click={() => selectedTab = 'performance'}>Performance</button>
        <button class:active={selectedTab === 'storage'} on:click={() => selectedTab = 'storage'}>Storage</button>
        <button class:active={selectedTab === 'queries'} on:click={() => selectedTab = 'queries'}>Queries</button>
      </div>
    </div>
    <div class="header-right">
      <select bind:value={timeRange} class="time-select">
        <option value="15m">15m</option>
        <option value="1h">1h</option>
        <option value="6h">6h</option>
        <option value="24h">24h</option>
      </select>
      <button class="refresh-btn" aria-label="Refresh analytics" on:click={fetchAnalytics} disabled={loading}>
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class:spinning={loading}>
          <path d="M23 4v6h-6M1 20v-6h6"/><path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
        </svg>
      </button>
    </div>
  </header>

  {#if error}
    <div class="error-banner">{error}</div>
  {/if}

  {#if loading && !stats}
    <div class="loading"><div class="spinner"></div></div>
  {:else}
    <!-- Status Bar -->
    <div class="status-bar">
      <span class:ok={getUptimeStatus() === 'healthy'} class:warn={getUptimeStatus() === 'warning'}><i></i>System</span>
      <span class:ok={errorRate < 1} class:warn={errorRate >= 1}><i></i>Errors: {errorRate}%</span>
      <span class:ok={cacheHitRate > 50} class:warn={cacheHitRate <= 50}><i></i>Cache: {clickhouseMetrics?.cache?.hit_rate || '0%'}</span>
      <span class="ok"><i></i>ClickHouse</span>
    </div>

    {#if selectedTab === 'overview'}
      <!-- Metrics Row -->
      <div class="metrics-row">
        <div class="metric">
          <div class="metric-main">
            <span class="metric-val">{formatNumber(stats?.total_logs)}</span>
            <span class="metric-lbl">Logs</span>
          </div>
          <span class="metric-trend">+{formatNumber(clickhouseMetrics?.ingestion?.total || 0)}</span>
        </div>
        <div class="metric">
          <div class="metric-main">
            <span class="metric-val">{stats?.db_size_mb || 0} MB</span>
            <span class="metric-lbl">Storage</span>
          </div>
        </div>
        <div class="metric">
          <div class="metric-main">
            <span class="metric-val">{clickhouseMetrics?.server?.uptime_human || '-'}</span>
            <span class="metric-lbl">Uptime</span>
          </div>
        </div>
        <div class="metric">
          <div class="metric-main">
            <span class="metric-val">{formatNumber(clickhouseMetrics?.requests?.total || 0)}</span>
            <span class="metric-lbl">Requests</span>
          </div>
          <span class="metric-err">{clickhouseMetrics?.requests?.errors || 0} err</span>
        </div>
      </div>

      <!-- Grid -->
      <div class="grid">
        <!-- Query Performance -->
        <div class="card">
          <div class="card-head"><h3>Query Performance</h3><span class="badge">{formatNumber(clickhouseMetrics?.clickhouse?.queries_total)}</span></div>
          <div class="perf-list">
            <div class="perf-row">
              <span>Avg Response</span>
              <span class="mono">{clickhouseMetrics?.clickhouse?.avg_query_time || '0s'}</span>
            </div>
            <div class="perf-row">
              <span>Cache Hit</span>
              <span class="mono">{clickhouseMetrics?.cache?.hit_rate || '0%'}</span>
            </div>
            <div class="perf-row">
              <span>Error Rate</span>
              <span class="mono">{errorRate}%</span>
            </div>
          </div>
        </div>

        <!-- Storage -->
        <div class="card">
          <div class="card-head"><h3>Storage</h3></div>
          <div class="storage-grid">
            <div class="storage-ring">
              <svg viewBox="0 0 36 36">
                <path class="ring-bg" d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"/>
                <path class="ring-fill" stroke-dasharray="75, 100" d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"/>
              </svg>
              <div class="ring-text"><span>{stats?.db_size_mb || 0}</span><small>MB</small></div>
            </div>
            <div class="storage-info">
              <div><span>Rows</span><span class="mono">{formatNumber(stats?.total_rows)}</span></div>
              <div><span>Oldest</span><span class="mono">{stats?.oldest_log?.split(' ')[0] || '-'}</span></div>
              <div><span>Newest</span><span class="mono">{stats?.newest_log?.split(' ')[0] || '-'}</span></div>
              <div><span>TTL</span><span class="mono">30d</span></div>
            </div>
          </div>
        </div>

        <!-- Ingestion -->
        <div class="card">
          <div class="card-head"><h3>Ingestion</h3><span class="badge live">Live</span></div>
          <div class="stats-grid">
            <div><span class="stat-val">{formatNumber(clickhouseMetrics?.ingestion?.total)}</span><span class="stat-lbl">Ingested</span></div>
            <div><span class="stat-val">{formatBytes(clickhouseMetrics?.clickhouse?.bytes_inserted)}</span><span class="stat-lbl">Written</span></div>
            <div><span class="stat-val">{clickhouseMetrics?.clickhouse?.buffer_size || 0}</span><span class="stat-lbl">Buffer</span></div>
            <div><span class="stat-val">{formatNumber(clickhouseMetrics?.clickhouse?.inserts_total)}</span><span class="stat-lbl">Inserts</span></div>
          </div>
        </div>

        <!-- Cache -->
        <div class="card">
          <div class="card-head"><h3>Cache</h3></div>
          <div class="cache-row">
            <div><span class="cache-val">{clickhouseMetrics?.cache?.hit_rate || '0%'}</span><span class="cache-lbl">Hit Rate</span></div>
            <div><span class="cache-val">{clickhouseMetrics?.cache?.entries || 0}</span><span class="cache-lbl">Entries</span></div>
            <div><span class="cache-val">{clickhouseMetrics?.cache?.ttl_seconds || 60}s</span><span class="cache-lbl">TTL</span></div>
          </div>
        </div>
      </div>
    {/if}

    {#if selectedTab === 'performance'}
      <!-- Endpoints -->
      <div class="card wide">
        <div class="card-head"><h3>Endpoints</h3></div>
        <div class="endpoint-list">
          {#if clickhouseMetrics?.requests?.by_path}
            {#each Object.entries(clickhouseMetrics.requests.by_path).sort((a, b) => b[1] - a[1]).slice(0, 8) as [path, count]}
              <div class="endpoint-row">
                <code>{path}</code>
                <div class="endpoint-bar"><div style="width: {Math.min(count / Math.max(...Object.values(clickhouseMetrics.requests.by_path)) * 100, 100)}%"></div></div>
                <span>{formatNumber(count)}</span>
              </div>
            {/each}
          {:else}
            <div class="no-data">No data</div>
          {/if}
        </div>
      </div>

      <div class="grid cols-2">
        <div class="card">
          <div class="card-head"><h3>Response Times</h3></div>
          <div class="time-list">
            <div><span>Average</span><span class="mono">{clickhouseMetrics?.requests?.avg_duration || '0'}s</span></div>
            <div><span>Total Time</span><span class="mono">{formatDuration((clickhouseMetrics?.clickhouse?.queries_total || 0) * avgQueryTime * 1000)}</span></div>
          </div>
        </div>
        <div class="card">
          <div class="card-head"><h3>Throughput</h3></div>
          <div class="throughput">
            <div><span class="tp-val">{formatNumber(clickhouseMetrics?.requests?.total || 0)}</span><span class="tp-lbl">Requests</span></div>
            <div><span class="tp-val">{formatBytes(clickhouseMetrics?.clickhouse?.bytes_inserted || 0)}</span><span class="tp-lbl">Processed</span></div>
          </div>
        </div>
      </div>
    {/if}

    {#if selectedTab === 'storage'}
      <div class="card wide">
        <div class="card-head"><h3>Tables</h3><span class="badge">{tableStats.length}</span></div>
        {#if tableStats.length > 0}
          <table class="data-table">
            <thead><tr><th>Table</th><th>Rows</th><th>Size</th><th>Parts</th><th>Comp</th></tr></thead>
            <tbody>
              {#each tableStats as t}
                <tr>
                  <td><code>{t.table}</code></td>
                  <td class="mono">{formatNumber(t.rows)}</td>
                  <td class="mono">{formatBytes(t.bytes)}</td>
                  <td class="mono">{t.partitions || '-'}</td>
                  <td>ZSTD</td>
                </tr>
              {/each}
            </tbody>
          </table>
        {:else}
          <div class="no-data">No tables</div>
        {/if}
      </div>

      <div class="grid cols-2">
        <div class="card">
          <div class="card-head"><h3>Distribution</h3></div>
          <div class="dist-list">
            {#each tableStats.slice(0, 4) as t}
              <div class="dist-row">
                <span>{t.table}</span>
                <div class="dist-bar"><div style="width: {t.bytes / Math.max(...tableStats.map(x => x.bytes)) * 100}%"></div></div>
                <span class="mono">{formatBytes(t.bytes)}</span>
              </div>
            {/each}
          </div>
        </div>
        <div class="card">
          <div class="card-head"><h3>Retention</h3></div>
          <div class="retention">
            <div><span>Policy</span><span>30 days</span></div>
            <div><span>Cleanup</span><span class="ok-text">Enabled</span></div>
            <div><span>Compression</span><span>ZSTD L3</span></div>
          </div>
        </div>
      </div>
    {/if}

    {#if selectedTab === 'queries'}
      <div class="card wide">
        <div class="card-head"><h3>Slow Queries</h3><span class="badge warn">&gt;100ms</span></div>
        {#if queryStats.length > 0}
          <table class="data-table">
            <thead><tr><th>Query</th><th>Time</th><th>Rows</th><th>Mem</th></tr></thead>
            <tbody>
              {#each queryStats as q}
                <tr>
                  <td><code class="query-text">{q.query?.substring(0, 60)}...</code></td>
                  <td class="mono" class:slow={q.duration_ms > 500}>{formatDuration(q.duration_ms)}</td>
                  <td class="mono">{formatNumber(q.read_rows)}</td>
                  <td class="mono">{formatBytes(q.memory_usage)}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        {:else}
          <div class="no-data">No slow queries</div>
        {/if}
      </div>

      <div class="grid cols-2">
        <div class="card">
          <div class="card-head"><h3>Query Stats</h3></div>
          <div class="query-stats">
            <div><span>Total</span><span class="mono">{formatNumber(clickhouseMetrics?.clickhouse?.queries_total)}</span></div>
            <div><span>Cached</span><span class="mono">{formatNumber(clickhouseMetrics?.clickhouse?.queries_cached)}</span></div>
            <div><span>Failed</span><span class="mono err">{formatNumber(clickhouseMetrics?.clickhouse?.errors_total)}</span></div>
            <div><span>Avg Time</span><span class="mono">{clickhouseMetrics?.clickhouse?.avg_query_time || '0s'}</span></div>
          </div>
        </div>
        <div class="card">
          <div class="card-head"><h3>Tips</h3></div>
          <div class="tips">
            <p>Use time filters to reduce scans</p>
            <p>Leverage indexed columns</p>
            <p>Use LIMIT clause</p>
          </div>
        </div>
      </div>
    {/if}
  {/if}
</div>

<style>
  .analytics-page {
    padding: 20px 24px;
    max-width: 100%;
    margin: 0;
  }

  /* Header */
  .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
    gap: 16px;
    flex-wrap: wrap;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 16px;
  }

  .header h1 {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .tabs {
    display: flex;
    gap: 2px;
    background: #161b22;
    padding: 3px;
    border-radius: 8px;
    border: 1px solid #30363d;
  }

  .tabs button {
    padding: 8px 16px;
    background: transparent;
    border: none;
    border-radius: 6px;
    color: #8b949e;
    font-size: 0.875rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .tabs button:hover { color: #c9d1d9; background: #21262d50; }
  .tabs button.active { background: #21262d; color: #f0f6fc; }

  .header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .time-select {
    padding: 8px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.875rem;
  }

  .refresh-btn {
    width: 36px;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    transition: all 0.15s;
  }

  .refresh-btn:hover { background: #30363d; }
  .spinning { animation: spin 1s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* Error */
  .error-banner {
    background: #f8514915;
    border: 1px solid #f85149;
    color: #f85149;
    padding: 6px 10px;
    border-radius: 4px;
    margin-bottom: 10px;
    font-size: 0.75rem;
  }

  /* Loading */
  .loading {
    display: flex;
    justify-content: center;
    padding: 40px;
  }

  .spinner {
    width: 24px;
    height: 24px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  /* Status Bar */
  .status-bar {
    display: flex;
    gap: 16px;
    padding: 10px 16px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    margin-bottom: 16px;
    flex-wrap: wrap;
  }

  .status-bar span {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 0.8125rem;
    color: #8b949e;
  }

  .status-bar i {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #484f58;
  }

  .status-bar .ok i { background: #3fb950; }
  .status-bar .warn i { background: #d29922; }

  /* Metrics Row */
  .metrics-row {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 16px;
    margin-bottom: 16px;
  }

  @media (max-width: 1000px) {
    .metrics-row { grid-template-columns: repeat(2, 1fr); }
  }

  .metric {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
  }

  .metric-main {
    display: flex;
    flex-direction: column;
  }

  .metric-val {
    font-size: 1.75rem;
    font-weight: 600;
    color: #f0f6fc;
    line-height: 1.2;
  }

  .metric-lbl {
    font-size: 0.75rem;
    color: #8b949e;
    text-transform: uppercase;
    margin-top: 4px;
  }

  .metric-trend {
    font-size: 0.75rem;
    color: #3fb950;
  }

  .metric-err {
    font-size: 0.75rem;
    color: #f85149;
  }

  /* Grid */
  .grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 16px;
  }

  .grid.cols-2 {
    grid-template-columns: repeat(2, 1fr);
  }

  @media (max-width: 1200px) {
    .grid { grid-template-columns: repeat(2, 1fr); }
  }

  @media (max-width: 700px) {
    .grid, .grid.cols-2 { grid-template-columns: 1fr; }
  }

  /* Card */
  .card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
  }

  .card.wide {
    grid-column: 1 / -1;
    margin-bottom: 16px;
  }

  .card-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 14px 18px;
    border-bottom: 1px solid #21262d;
  }

  .card-head h3 {
    font-size: 0.9375rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .badge {
    font-size: 0.6875rem;
    padding: 4px 10px;
    background: #21262d;
    border-radius: 10px;
    color: #8b949e;
  }

  .badge.live { background: #3fb95020; color: #3fb950; }
  .badge.warn { background: #d2992220; color: #d29922; }

  /* Perf List */
  .perf-list {
    padding: 14px 18px;
  }

  .perf-row {
    display: flex;
    justify-content: space-between;
    font-size: 0.875rem;
    color: #8b949e;
    padding: 6px 0;
  }

  .perf-row .mono { color: #f0f6fc; }

  /* Storage Grid */
  .storage-grid {
    display: flex;
    padding: 18px;
    gap: 20px;
  }

  .storage-ring {
    position: relative;
    width: 80px;
    height: 80px;
    flex-shrink: 0;
  }

  .storage-ring svg {
    width: 100%;
    height: 100%;
    transform: rotate(-90deg);
  }

  .ring-bg { fill: none; stroke: #21262d; stroke-width: 3; }
  .ring-fill { fill: none; stroke: #3fb950; stroke-width: 3; stroke-linecap: round; }

  .ring-text {
    position: absolute;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    text-align: center;
    line-height: 1;
  }

  .ring-text span {
    display: block;
    font-size: 1.125rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .ring-text small {
    font-size: 0.625rem;
    color: #8b949e;
  }

  .storage-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .storage-info div {
    display: flex;
    justify-content: space-between;
    font-size: 0.8125rem;
    color: #8b949e;
  }

  .storage-info .mono { color: #f0f6fc; font-family: 'SF Mono', Monaco, monospace; }

  /* Stats Grid */
  .stats-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 1px;
    background: #21262d;
  }

  .stats-grid > div {
    display: flex;
    flex-direction: column;
    padding: 14px 18px;
    background: #161b22;
  }

  .stat-val {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .stat-lbl {
    font-size: 0.6875rem;
    color: #8b949e;
    text-transform: uppercase;
    margin-top: 4px;
  }

  /* Cache Row */
  .cache-row {
    display: flex;
    padding: 18px;
    gap: 16px;
  }

  .cache-row > div {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
  }

  .cache-val {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .cache-lbl {
    font-size: 0.6875rem;
    color: #8b949e;
    margin-top: 4px;
  }

  /* Endpoint List */
  .endpoint-list {
    padding: 14px 18px;
  }

  .endpoint-row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 0;
  }

  .endpoint-row code {
    width: 180px;
    font-size: 0.8125rem;
    color: #58a6ff;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .endpoint-bar {
    flex: 1;
    height: 6px;
    background: #21262d;
    border-radius: 3px;
    overflow: hidden;
  }

  .endpoint-bar div {
    height: 100%;
    background: linear-gradient(90deg, #388bfd, #a371f7);
    border-radius: 3px;
  }

  .endpoint-row > span {
    width: 50px;
    text-align: right;
    font-size: 0.8125rem;
    font-family: 'SF Mono', Monaco, monospace;
    color: #f0f6fc;
  }

  /* Time List */
  .time-list {
    padding: 14px 18px;
  }

  .time-list div {
    display: flex;
    justify-content: space-between;
    font-size: 0.875rem;
    color: #8b949e;
    padding: 8px 0;
  }

  .time-list .mono { color: #f0f6fc; font-family: 'SF Mono', Monaco, monospace; }

  /* Throughput */
  .throughput {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 1px;
    background: #21262d;
  }

  .throughput > div {
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 20px;
    background: #161b22;
  }

  .tp-val {
    font-size: 1.5rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .tp-lbl {
    font-size: 0.6875rem;
    color: #8b949e;
    text-transform: uppercase;
    margin-top: 6px;
  }

  /* Data Table */
  .data-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.875rem;
  }

  .data-table th,
  .data-table td {
    padding: 12px 18px;
    text-align: left;
    border-bottom: 1px solid #21262d;
  }

  .data-table th {
    background: #0d1117;
    font-size: 0.6875rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
  }

  .data-table td { color: #c9d1d9; }
  .data-table td code { color: #58a6ff; font-size: 0.8125rem; }
  .data-table .mono { font-family: 'SF Mono', Monaco, monospace; }
  .data-table .slow { color: #d29922; }

  .query-text {
    max-width: 300px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    display: inline-block;
  }

  /* Distribution */
  .dist-list {
    padding: 14px 18px;
  }

  .dist-row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 0;
    font-size: 0.8125rem;
    color: #8b949e;
  }

  .dist-row span:first-child {
    width: 100px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .dist-bar {
    flex: 1;
    height: 6px;
    background: #21262d;
    border-radius: 3px;
    overflow: hidden;
  }

  .dist-bar div {
    height: 100%;
    background: #3fb950;
    border-radius: 3px;
  }

  .dist-row .mono { color: #f0f6fc; width: 80px; text-align: right; }

  /* Retention */
  .retention {
    padding: 14px 18px;
  }

  .retention div {
    display: flex;
    justify-content: space-between;
    font-size: 0.875rem;
    color: #8b949e;
    padding: 8px 0;
  }

  .retention span:last-child { color: #f0f6fc; }
  .ok-text { color: #3fb950 !important; }

  /* Query Stats */
  .query-stats {
    padding: 14px 18px;
  }

  .query-stats div {
    display: flex;
    justify-content: space-between;
    font-size: 0.875rem;
    color: #8b949e;
    padding: 8px 0;
  }

  .query-stats .mono { color: #f0f6fc; font-family: 'SF Mono', Monaco, monospace; }
  .query-stats .err { color: #f85149; }

  /* Tips */
  .tips {
    padding: 14px 18px;
  }

  .tips p {
    font-size: 0.8125rem;
    color: #8b949e;
    margin: 0;
    padding: 6px 0;
  }

  /* No Data */
  .no-data {
    padding: 40px;
    text-align: center;
    color: #8b949e;
    font-size: 0.9375rem;
  }
</style>
