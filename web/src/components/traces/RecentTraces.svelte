<!--
  RecentTraces
  The Traces page's landing table: traces seen in the last 1h / 24h / 7d,
  fetched from GET /api/traces/recent. Clicking a row hands its trace_id to
  the parent, which runs the actual lookup.
-->
<script>
  import { onMount } from 'svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import { alertCircle, activity } from '../ui/icons.js';
  import { formatTimestamp, formatFullTimestamp, formatDuration } from '../../utils/format.js';
  import { api } from '../../utils/api.js';

  /**
   * @type {{
   *   serviceColor: (service: string) => string,
   *   onselect: (traceId: string) => void,
   * }}
   */
  let { serviceColor, onselect } = $props();

  const RANGES = ['1h', '24h', '7d'];

  let recentTraces = $state.raw([]);
  let recentLoading = $state(false);
  let recentRange = $state('24h');
  let recentError = $state('');

  async function fetchRecentTraces() {
    recentLoading = true;
    recentError = '';
    try {
      const data = await api.get('/traces/recent', { query: { range: recentRange, limit: 50 } });
      recentTraces = data.traces || [];
    } catch (err) {
      // status 0 means we never reached the server.
      recentError = err.status ? `Failed to load traces (${err.status})` : 'Failed to load recent traces';
    } finally {
      recentLoading = false;
    }
  }

  function changeRange(range) {
    recentRange = range;
    fetchRecentTraces();
  }

  onMount(fetchRecentTraces);
</script>

<div class="recent-section">
  <div class="recent-header">
    <h2>Recent Traces</h2>
    <div class="range-buttons">
      {#each RANGES as range (range)}
        <button
          class="range-btn"
          class:active={recentRange === range}
          onclick={() => changeRange(range)}
        >{range}</button>
      {/each}
    </div>
  </div>

  {#if recentLoading}
    <div class="loading-container">
      <LoadingSpinner size="md" label="Loading recent traces..." centered />
    </div>
  {:else if recentError}
    <div class="empty-wrap">
      <EmptyState icon={alertCircle} title={recentError} tone="error">
        {#snippet actions()}
          <button class="retry-btn" onclick={fetchRecentTraces}>Retry</button>
        {/snippet}
      </EmptyState>
    </div>
  {:else if recentTraces.length === 0}
    <div class="empty-wrap">
      <EmptyState icon={activity} title="No traces found">
        No distributed traces in the last {recentRange}. Send logs with trace_id to see them here.
      </EmptyState>
    </div>
  {:else}
    <div class="recent-table-wrapper">
      <table class="recent-table">
        <thead>
          <tr>
            <th>Trace ID</th>
            <th>Services</th>
            <th>Logs</th>
            <th>Errors</th>
            <th>Duration</th>
            <th>Last seen</th>
          </tr>
        </thead>
        <tbody>
          {#each recentTraces as trace}
            <tr class="trace-row" class:has-errors={trace.error_count > 0} onclick={() => onselect(trace.trace_id)}>
              <td class="col-trace-id">
                <span class="trace-id-text">{trace.trace_id}</span>
              </td>
              <td class="col-services">
                {#each (trace.services || []).slice(0, 3) as svc}
                  <span class="service-chip" style="border-color: {serviceColor(svc)}; color: {serviceColor(svc)}">{svc}</span>
                {/each}
                {#if (trace.services || []).length > 3}
                  <span class="service-more">+{trace.services.length - 3}</span>
                {/if}
              </td>
              <td class="col-count">{trace.log_count}</td>
              <td class="col-errors">
                {#if trace.error_count > 0}
                  <span class="error-count">{trace.error_count}</span>
                {:else}
                  <span class="muted">0</span>
                {/if}
              </td>
              <td class="col-duration">{formatDuration(trace.duration_ms)}</td>
              <td class="col-time">
                <span class="timestamp" title={formatFullTimestamp(trace.last_seen)}>
                  {formatTimestamp(trace.last_seen)}
                </span>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>

<style>
  .recent-section {
    flex: 1;
  }

  .recent-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
  }

  h2 {
    font-size: 0.75rem;
    font-weight: 600;
    color: #8b949e;
    margin: 0;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .loading-container {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 200px;
  }

  /* Keeps the content area from collapsing when an EmptyState replaces
     the table. */
  .empty-wrap {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 300px;
  }

  .retry-btn {
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 6px 16px;
    font-size: 0.8125rem;
    color: #c9d1d9;
    cursor: pointer;
    transition: background 0.15s;
    margin-top: 8px;
  }

  .retry-btn:hover {
    background: #30363d;
  }

  .range-buttons {
    display: flex;
    gap: 4px;
  }

  .range-btn {
    background: #21262d;
    border: 1px solid #30363d;
    color: #8b949e;
    padding: 4px 10px;
    border-radius: 6px;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .range-btn:hover {
    background: #30363d;
    color: #c9d1d9;
  }

  .range-btn.active {
    background: #388bfd26;
    border-color: #58a6ff;
    color: #58a6ff;
  }

  .recent-table-wrapper {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
  }

  .recent-table {
    width: 100%;
    border-collapse: collapse;
  }

  .recent-table th {
    background: #1c2128;
    padding: 8px 12px;
    text-align: left;
    font-size: 0.6875rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    border-bottom: 1px solid #30363d;
  }

  .recent-table td {
    padding: 8px 12px;
    font-size: 0.8125rem;
    color: #c9d1d9;
    border-bottom: 1px solid #21262d;
    vertical-align: middle;
  }

  .trace-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .trace-row:hover {
    background: rgba(88, 166, 255, 0.06);
  }

  .trace-row.has-errors {
    border-left: 3px solid #f85149;
  }

  .trace-id-text {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #58a6ff;
    max-width: 200px;
    display: inline-block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-services {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    align-items: center;
  }

  .service-chip {
    display: inline-block;
    padding: 1px 6px;
    font-size: 0.6875rem;
    font-weight: 500;
    border: 1px solid;
    border-radius: 4px;
    white-space: nowrap;
  }

  .service-more {
    font-size: 0.6875rem;
    color: #848d97;
  }

  .col-count, .col-errors, .col-duration, .col-time {
    white-space: nowrap;
  }

  .error-count {
    color: #f85149;
    font-weight: 600;
  }

  .timestamp {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #8b949e;
  }

  .muted {
    color: #848d97;
  }
</style>
