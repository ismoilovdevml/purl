<script>
  import { onMount, onDestroy } from 'svelte';
  import { formatBytes, formatNumber } from '../utils/format.js';

  let stats = null;
  let metrics = null;
  let tableStats = [];
  let slowQueries = [];
  let loading = true;
  let error = null;
  let refreshInterval;
  let lastUpdated = null;

  const API_BASE = '/api';

  async function fetchAnalytics() {
    try {
      const [statsRes, metricsRes, tableRes, queriesRes] = await Promise.all([
        fetch(`${API_BASE}/stats`),
        fetch(`${API_BASE}/metrics/json`),
        fetch(`${API_BASE}/analytics/tables`),
        fetch(`${API_BASE}/analytics/queries?limit=5`),
      ]);

      stats = await statsRes.json();
      metrics = await metricsRes.json();

      if (tableRes.ok) {
        const tData = await tableRes.json();
        tableStats = tData.tables || [];
      }

      if (queriesRes.ok) {
        const qData = await queriesRes.json();
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
  $: requestsTotal = metrics?.requests?.total || 0;
  $: errorsTotal = metrics?.requests?.errors || 0;
  $: errorRate = requestsTotal > 0 ? ((errorsTotal / requestsTotal) * 100).toFixed(2) : '0.00';
  $: cacheHitRate = metrics?.cache?.hit_rate || '0%';
  $: avgQueryTime = metrics?.clickhouse?.avg_query_time || '0s';
  $: totalStorage = tableStats.reduce((acc, t) => acc + (t.bytes || 0), 0);
  $: uptimeHuman = metrics?.server?.uptime_human || '-';
  $: uptimeSecs = metrics?.server?.uptime_secs || 0;

  // Request metrics
  $: requestsPerSec = metrics?.requests?.per_second || '0';
  $: p50Latency = metrics?.requests?.p50_latency || '0ms';
  $: p95Latency = metrics?.requests?.p95_latency || '0ms';
  $: p99Latency = metrics?.requests?.p99_latency || '0ms';
  $: maxLatency = metrics?.requests?.max_latency || '0ms';
  $: bytesIn = metrics?.requests?.bytes_in || 0;
  $: bytesOut = metrics?.requests?.bytes_out || 0;

  // SLA and health
  $: slaCompliance = parseFloat(errorRate) < 1 ? 99.9 : (100 - parseFloat(errorRate)).toFixed(1);
  $: healthScore = calculateHealthScore();
  $: healthFactors = getHealthFactors();

  function calculateHealthScore() {
    const factors = getHealthFactors();
    const totalWeight = factors.reduce((sum, f) => sum + f.weight, 0);
    const weightedScore = factors.reduce((sum, f) => sum + (f.score * f.weight), 0);
    return Math.round(weightedScore / totalWeight);
  }

  function getHealthFactors() {
    const factors = [];

    // 1. Error Rate (weight: 30) - most critical
    const errRate = parseFloat(errorRate) || 0;
    let errScore = 100;
    if (errRate > 10) errScore = 0;
    else if (errRate > 5) errScore = 30;
    else if (errRate > 1) errScore = 60;
    else if (errRate > 0) errScore = 85;
    factors.push({ name: 'Error Rate', score: errScore, weight: 30, value: `${errRate.toFixed(2)}%`, status: errScore >= 85 ? 'good' : errScore >= 60 ? 'warn' : 'bad' });

    // 2. P95 Latency (weight: 25)
    const p95Val = parseFloat(p95Latency) || 0;
    let p95Score = 100;
    if (p95Val > 1000) p95Score = 20;
    else if (p95Val > 500) p95Score = 50;
    else if (p95Val > 200) p95Score = 70;
    else if (p95Val > 100) p95Score = 85;
    factors.push({ name: 'P95 Latency', score: p95Score, weight: 25, value: p95Latency, status: p95Score >= 85 ? 'good' : p95Score >= 60 ? 'warn' : 'bad' });

    // 3. P99 Latency (weight: 15)
    const p99Val = parseFloat(p99Latency) || 0;
    let p99Score = 100;
    if (p99Val > 2000) p99Score = 20;
    else if (p99Val > 1000) p99Score = 50;
    else if (p99Val > 500) p99Score = 70;
    else if (p99Val > 200) p99Score = 85;
    factors.push({ name: 'P99 Latency', score: p99Score, weight: 15, value: p99Latency, status: p99Score >= 85 ? 'good' : p99Score >= 60 ? 'warn' : 'bad' });

    // 4. Cache Hit Rate (weight: 15)
    const cacheVal = parseFloat(cacheHitRate) || 0;
    let cacheScore = 100;
    if (cacheVal < 10) cacheScore = 30;
    else if (cacheVal < 30) cacheScore = 60;
    else if (cacheVal < 50) cacheScore = 80;
    factors.push({ name: 'Cache Hit Rate', score: cacheScore, weight: 15, value: cacheHitRate, status: cacheScore >= 80 ? 'good' : cacheScore >= 60 ? 'warn' : 'bad' });

    // 5. Uptime (weight: 10)
    const uptimeVal = uptimeSecs || 0;
    let uptimeScore = 100;
    if (uptimeVal < 60) uptimeScore = 50; // < 1 min - just started
    else if (uptimeVal < 300) uptimeScore = 70; // < 5 min
    else if (uptimeVal < 3600) uptimeScore = 90; // < 1 hour
    factors.push({ name: 'Uptime', score: uptimeScore, weight: 10, value: uptimeHuman, status: uptimeScore >= 90 ? 'good' : uptimeScore >= 70 ? 'warn' : 'bad' });

    // 6. Throughput (weight: 5) - bonus for handling load
    const rpsVal = parseFloat(requestsPerSec) || 0;
    let rpsScore = 70; // baseline
    if (rpsVal > 100) rpsScore = 100;
    else if (rpsVal > 10) rpsScore = 90;
    else if (rpsVal > 1) rpsScore = 80;
    factors.push({ name: 'Throughput', score: rpsScore, weight: 5, value: `${rpsVal}/s`, status: rpsScore >= 80 ? 'good' : rpsScore >= 70 ? 'warn' : 'bad' });

    return factors;
  }

  function getHealthColor(score) {
    if (score >= 90) return '#3fb950';
    if (score >= 70) return '#d29922';
    return '#f85149';
  }

  function getLatencyColor(ms) {
    const val = parseFloat(ms);
    if (val < 50) return '#3fb950';
    if (val < 200) return '#d29922';
    return '#f85149';
  }
</script>

<div class="analytics">
  <!-- Header -->
  <header>
    <div class="header-left">
      <h1>Analytics</h1>
      <div class="health-badge-wrapper">
        <div class="health-badge" style="--health-color: {getHealthColor(healthScore)}">
          <span class="health-score">{healthScore}</span>
          <span class="health-label">Health</span>
        </div>
        <div class="health-tooltip">
          <div class="tooltip-header">Health Score Breakdown</div>
          {#each healthFactors as factor}
            <div class="tooltip-row">
              <span class="factor-name">{factor.name}</span>
              <span class="factor-value">{factor.value}</span>
              <span class="factor-score {factor.status}">{factor.score}</span>
              <span class="factor-weight">×{factor.weight}%</span>
            </div>
          {/each}
          <div class="tooltip-total">
            <span>Total Score</span>
            <span class="total-score" style="color: {getHealthColor(healthScore)}">{healthScore}</span>
          </div>
        </div>
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
            <span class="value">{formatNumber(metrics?.clickhouse?.queries_cached)}</span>
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
            <span class="value">{formatBytes(metrics?.clickhouse?.bytes_inserted)}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Rows</span>
            <span class="value">{formatNumber(stats?.total_logs)}</span>
          </div>
        </div>
      </div>

      <!-- Latency Percentiles -->
      <div class="card">
        <h2>Latency</h2>
        <div class="mini-stats">
          <div class="mini-stat">
            <span class="label">P50</span>
            <span class="value" style="color: {getLatencyColor(p50Latency)}">{p50Latency}</span>
          </div>
          <div class="mini-stat">
            <span class="label">P95</span>
            <span class="value" style="color: {getLatencyColor(p95Latency)}">{p95Latency}</span>
          </div>
          <div class="mini-stat">
            <span class="label">P99</span>
            <span class="value" style="color: {getLatencyColor(p99Latency)}">{p99Latency}</span>
          </div>
          <div class="mini-stat">
            <span class="label">Max</span>
            <span class="value" style="color: {getLatencyColor(maxLatency)}">{maxLatency}</span>
          </div>
        </div>
      </div>
    </div>

    <!-- Bottom Section -->
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
            <span class="cache-value">{formatBytes(bytesIn)}</span>
            <span class="cache-label">In</span>
          </div>
          <div class="cache-item">
            <span class="cache-value">{formatBytes(bytesOut)}</span>
            <span class="cache-label">Out</span>
          </div>
        </div>
      </div>
    </div>

    <!-- Slow Queries Section -->
    {#if slowQueries.length > 0}
      <div class="card slow-queries-card">
        <h2>Slow Queries <span class="count">{slowQueries.length}</span></h2>
        <div class="queries-list">
          {#each slowQueries as q, i}
            <div class="query-row">
              <span class="query-rank">#{i + 1}</span>
              <span class="query-time">{q.query_duration_ms?.toFixed(0) || '-'}ms</span>
              <span class="query-text" title={q.query}>{q.query?.substring(0, 80) || '-'}...</span>
            </div>
          {/each}
        </div>
      </div>
    {/if}
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

  .health-badge-wrapper {
    position: relative;
  }

  .health-badge {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 12px;
    background: rgba(63, 185, 80, 0.1);
    border: 1px solid var(--health-color);
    border-radius: 20px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .health-badge:hover {
    background: rgba(63, 185, 80, 0.15);
    transform: scale(1.02);
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

  .health-tooltip {
    position: absolute;
    top: calc(100% + 8px);
    left: 0;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 12px;
    min-width: 280px;
    z-index: 1000;
    opacity: 0;
    visibility: hidden;
    transform: translateY(-4px);
    transition: all 0.15s;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
  }

  .health-badge-wrapper:hover .health-tooltip {
    opacity: 1;
    visibility: visible;
    transform: translateY(0);
  }

  .tooltip-header {
    font-size: 0.75rem;
    font-weight: 600;
    color: #f0f6fc;
    margin-bottom: 10px;
    padding-bottom: 8px;
    border-bottom: 1px solid #21262d;
  }

  .tooltip-row {
    display: grid;
    grid-template-columns: 1fr auto auto auto;
    gap: 8px;
    align-items: center;
    padding: 4px 0;
    font-size: 0.75rem;
  }

  .factor-name {
    color: #8b949e;
  }

  .factor-value {
    color: #c9d1d9;
    font-family: monospace;
    text-align: right;
  }

  .factor-score {
    width: 28px;
    text-align: center;
    font-weight: 600;
    padding: 2px 4px;
    border-radius: 4px;
  }

  .factor-score.good {
    color: #3fb950;
    background: rgba(63, 185, 80, 0.1);
  }

  .factor-score.warn {
    color: #d29922;
    background: rgba(210, 153, 34, 0.1);
  }

  .factor-score.bad {
    color: #f85149;
    background: rgba(248, 81, 73, 0.1);
  }

  .factor-weight {
    color: #6e7681;
    font-size: 0.625rem;
    width: 32px;
  }

  .tooltip-total {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-top: 10px;
    padding-top: 8px;
    border-top: 1px solid #21262d;
    font-weight: 600;
    color: #f0f6fc;
  }

  .total-score {
    font-size: 1.125rem;
    font-weight: 700;
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
    margin-bottom: 12px;
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

  /* Slow Queries */
  .slow-queries-card {
    margin-top: 0;
  }

  .queries-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .query-row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px 12px;
    background: #0d1117;
    border-radius: 6px;
  }

  .query-rank {
    font-size: 0.75rem;
    color: #6e7681;
    min-width: 24px;
  }

  .query-time {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #d29922;
    min-width: 60px;
  }

  .query-text {
    font-family: "SFMono-Regular", Consolas, monospace;
    font-size: 0.75rem;
    color: #8b949e;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
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
