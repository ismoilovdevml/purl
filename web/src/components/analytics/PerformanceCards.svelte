<!--
  PerformanceCards
  The three-column row on the Analytics page: query performance, live
  ingestion counters and request latency percentiles (colour-coded by speed).
-->
<script>
  import { formatBytes, formatNumber } from '../../utils/format.js';

  let {
    /** Latest /metrics/json payload (null before the first poll) */
    metrics,
    /** Latest /stats payload (null before the first poll) */
    stats,
    /** Average ClickHouse query time string */
    avgQueryTime,
    /** Cache hit rate string, e.g. '37%' */
    cacheHitRate,
    /** Latency percentile strings, e.g. '12ms' */
    p50Latency,
    p95Latency,
    p99Latency,
    maxLatency,
  } = $props();

  function getLatencyColor(ms) {
    const val = parseFloat(ms);
    if (val < 50) return '#3fb950';
    if (val < 200) return '#d29922';
    return '#f85149';
  }
</script>

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

<style>
  /* .card and h2 are duplicated in ResourceCards: each Analytics section
     component renders its own cards, and scoped styles do not cross files. */
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
    font-size: 0.6875rem;
    padding: 2px 6px;
    border-radius: 8px;
    font-weight: 500;
  }

  @media (max-width: 800px) {
    .three-columns {
      grid-template-columns: 1fr;
    }
  }
</style>
