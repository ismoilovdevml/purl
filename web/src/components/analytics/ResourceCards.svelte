<!--
  ResourceCards
  The lower half of the Analytics page: ClickHouse table sizes, the query
  cache (with its Clear Cache action), request throughput, and — when the
  backend reports any — the slowest recent queries.
-->
<script>
  import { formatBytes, formatNumber } from '../../utils/format.js';

  let {
    /** Latest /metrics/json payload (null before the first poll) */
    metrics,
    /** Rows from /analytics/tables */
    tableStats = [],
    /** Rows from /analytics/queries */
    slowQueries = [],
    /** Cache hit rate string, e.g. '37%' */
    cacheHitRate,
    /** Requests per second (string or number) */
    requestsPerSec,
    /** Bytes received / sent by the API */
    bytesIn,
    bytesOut,
    /** A cache clear is in flight */
    clearingCache = false,
    /** () => void — Clear Cache clicked */
    onclearcache,
  } = $props();
</script>

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
    <div class="card-header">
      <h2>Cache</h2>
      <button class="clear-cache-btn" onclick={onclearcache} disabled={clearingCache}>
        {#if clearingCache}
          Clearing...
        {:else}
          Clear Cache
        {/if}
      </button>
    </div>
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

<style>
  /* .card and h2 are duplicated in PerformanceCards: each Analytics section
     component renders its own cards, and scoped styles do not cross files. */
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
    font-family: var(--font-mono);
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
    color: #848d97;
    min-width: 70px;
    text-align: right;
  }

  /* Card Header */
  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 10px;
  }

  .card-header h2 {
    margin-bottom: 0;
  }

  .clear-cache-btn {
    padding: 4px 10px;
    font-size: 0.6875rem;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #c9d1d9;
    cursor: pointer;
    transition: all 0.15s;
  }

  .clear-cache-btn:hover {
    background: #30363d;
    border-color: #8b949e;
  }

  .clear-cache-btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
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
    color: #848d97;
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
    color: #848d97;
    min-width: 24px;
  }

  .query-time {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #d29922;
    min-width: 60px;
  }

  .query-text {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #8b949e;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  }

  /* Responsive */
  @media (max-width: 1200px) {
    .bottom-grid {
      grid-template-columns: 1fr 1fr;
    }
  }

  @media (max-width: 800px) {
    .bottom-grid {
      grid-template-columns: 1fr;
    }
  }
</style>
