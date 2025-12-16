<script>
  import { onMount, onDestroy } from 'svelte';
  import {
    tracesList,
    tracesListLoading,
    tracesListError,
    tracesServiceFilter,
    fetchRecentTraces,
    formatDuration,
    getServiceColor,
    resetServiceColors
  } from '../stores/traces.js';
  import TraceView from './TraceView.svelte';

  let selectedRange = '1h';
  let selectedTraceId = null;
  let serviceFilter = null;

  // Subscribe to service filter changes
  const unsubscribe = tracesServiceFilter.subscribe(value => {
    serviceFilter = value;
    if (value) {
      resetServiceColors();
      fetchRecentTraces(selectedRange, 50, value);
    }
  });

  function handleRangeChange(range) {
    selectedRange = range;
    resetServiceColors();
    fetchRecentTraces(range, 50, serviceFilter);
  }

  function selectTrace(traceId) {
    selectedTraceId = traceId;
  }

  function closeTraceView() {
    selectedTraceId = null;
  }

  function clearServiceFilter() {
    tracesServiceFilter.set(null);
    serviceFilter = null;
    resetServiceColors();
    fetchRecentTraces(selectedRange);
  }

  function formatTimestamp(ts) {
    if (!ts) return '';
    const date = new Date(ts);
    return date.toLocaleString('en-US', {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false
    });
  }

  function getHealthClass(errorCount) {
    if (errorCount === 0) return 'healthy';
    if (errorCount <= 2) return 'degraded';
    return 'critical';
  }

  onMount(() => {
    fetchRecentTraces(selectedRange, 50, serviceFilter);
  });

  onDestroy(() => {
    unsubscribe();
  });
</script>

<div class="traces-page">
  {#if selectedTraceId}
    <TraceView traceId={selectedTraceId} onClose={closeTraceView} />
  {:else}
    <div class="traces-header">
      <div class="header-left">
        <h2>Traces</h2>
        <span class="trace-count">{$tracesList.length} traces</span>
        {#if serviceFilter}
          <div class="service-filter-badge">
            <span>Service: {serviceFilter}</span>
            <button class="clear-filter" on:click={clearServiceFilter} title="Clear filter">×</button>
          </div>
        {/if}
      </div>

      <div class="header-right">
        <div class="time-range">
          {#each ['15m', '1h', '6h', '24h'] as range}
            <button
              class:active={selectedRange === range}
              on:click={() => handleRangeChange(range)}
            >
              {range}
            </button>
          {/each}
        </div>
        <button class="refresh-btn" on:click={() => fetchRecentTraces(selectedRange, 50, serviceFilter)} disabled={$tracesListLoading}>
          {#if $tracesListLoading}
            <span class="spinner"></span>
          {:else}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M23 4v6h-6M1 20v-6h6M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
            </svg>
          {/if}
          Refresh
        </button>
      </div>
    </div>

    {#if $tracesListError}
      <div class="error-banner">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="12" cy="12" r="10"/><path d="M12 8v4M12 16h.01"/>
        </svg>
        {$tracesListError}
      </div>
    {/if}

    <div class="traces-content">
      {#if $tracesListLoading && $tracesList.length === 0}
        <div class="loading-state">
          <div class="loading-spinner"></div>
          <span>Loading traces...</span>
        </div>
      {:else if $tracesList.length === 0}
        <div class="empty-state">
          <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
            <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
          </svg>
          <h3>No Traces Found</h3>
          <p>Traces will appear here once logs with trace IDs are ingested.</p>
          <p class="hint">Add <code>trace_id</code> to your log entries to enable distributed tracing.</p>
        </div>
      {:else}
        <div class="traces-table">
          <div class="table-header">
            <div class="col-trace">Trace ID</div>
            <div class="col-services">Services</div>
            <div class="col-spans">Spans</div>
            <div class="col-duration">Duration</div>
            <div class="col-errors">Errors</div>
            <div class="col-time">Started</div>
          </div>

          <div class="table-body">
            {#each $tracesList as trace}
              <button
                class="trace-row"
                class:has-errors={trace.error_count > 0}
                on:click={() => selectTrace(trace.trace_id)}
              >
                <div class="col-trace">
                  <span class="trace-id">{trace.trace_id.slice(0, 8)}...</span>
                  {#if trace.root_message}
                    <span class="root-message">{trace.root_message.slice(0, 60)}{trace.root_message.length > 60 ? '...' : ''}</span>
                  {/if}
                </div>
                <div class="col-services">
                  <div class="service-badges">
                    {#each (trace.services || []).slice(0, 3) as service}
                      <span class="service-badge" style="background-color: {getServiceColor(service)}">{service}</span>
                    {/each}
                    {#if (trace.services || []).length > 3}
                      <span class="more-badge">+{trace.services.length - 3}</span>
                    {/if}
                  </div>
                </div>
                <div class="col-spans">
                  <span class="span-count">{trace.span_count}</span>
                  <span class="span-label">spans</span>
                </div>
                <div class="col-duration">
                  <span class="duration">{formatDuration(trace.duration_ms)}</span>
                </div>
                <div class="col-errors">
                  <span class="error-count health-{getHealthClass(trace.error_count)}">{trace.error_count}</span>
                </div>
                <div class="col-time">
                  <span class="timestamp">{formatTimestamp(trace.start_time)}</span>
                </div>
              </button>
            {/each}
          </div>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .traces-page {
    height: 100%;
    display: flex;
    flex-direction: column;
    background: #0d1117;
    color: #c9d1d9;
  }

  .traces-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 16px 20px;
    border-bottom: 1px solid #21262d;
    background: #161b22;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }

  .header-left h2 {
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    color: #f0f6fc;
  }

  .service-filter-badge {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    background: rgba(88, 166, 255, 0.15);
    border: 1px solid rgba(88, 166, 255, 0.3);
    border-radius: 16px;
    font-size: 12px;
    color: #58a6ff;
  }

  .clear-filter {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    height: 16px;
    padding: 0;
    border: none;
    background: rgba(88, 166, 255, 0.2);
    color: #58a6ff;
    border-radius: 50%;
    cursor: pointer;
    font-size: 14px;
    line-height: 1;
  }

  .clear-filter:hover {
    background: rgba(88, 166, 255, 0.4);
  }

  .trace-count {
    font-size: 12px;
    color: #8b949e;
    background: #21262d;
    padding: 4px 10px;
    border-radius: 12px;
  }

  .header-right {
    display: flex;
    gap: 12px;
    align-items: center;
  }

  .time-range {
    display: flex;
    gap: 2px;
    background: #21262d;
    padding: 4px;
    border-radius: 8px;
  }

  .time-range button {
    padding: 6px 14px;
    border: none;
    background: transparent;
    color: #8b949e;
    border-radius: 6px;
    cursor: pointer;
    font-size: 13px;
    font-weight: 500;
    transition: all 0.15s;
  }

  .time-range button:hover {
    color: #c9d1d9;
    background: rgba(255,255,255,0.05);
  }

  .time-range button.active {
    background: #58a6ff;
    color: #fff;
  }

  .refresh-btn {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 16px;
    border: 1px solid #30363d;
    background: #0d1117;
    color: #c9d1d9;
    border-radius: 8px;
    cursor: pointer;
    font-size: 13px;
    transition: all 0.2s;
  }

  .refresh-btn:hover {
    background: #21262d;
    border-color: #58a6ff;
  }

  .refresh-btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .error-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 20px;
    background: rgba(239, 68, 68, 0.1);
    border-bottom: 1px solid rgba(239, 68, 68, 0.3);
    color: #ef4444;
    font-size: 13px;
  }

  .traces-content {
    flex: 1;
    overflow: auto;
    padding: 16px 20px;
  }

  .loading-state,
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 80px 20px;
    text-align: center;
  }

  .loading-spinner {
    width: 40px;
    height: 40px;
    border: 3px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    margin-bottom: 16px;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .empty-state svg {
    margin-bottom: 20px;
    opacity: 0.4;
    color: #8b949e;
  }

  .empty-state h3 {
    margin: 0 0 8px;
    font-size: 18px;
    color: #f0f6fc;
  }

  .empty-state p {
    margin: 0 0 8px;
    color: #8b949e;
    font-size: 14px;
  }

  .empty-state .hint {
    font-size: 12px;
    opacity: 0.7;
  }

  .empty-state code {
    background: #21262d;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #58a6ff;
  }

  .traces-table {
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 12px;
    overflow: hidden;
  }

  .table-header {
    display: grid;
    grid-template-columns: 2fr 1.5fr 0.7fr 0.8fr 0.6fr 1fr;
    padding: 12px 16px;
    background: #0d1117;
    border-bottom: 1px solid #21262d;
    font-size: 11px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .table-body {
    max-height: calc(100vh - 260px);
    overflow-y: auto;
  }

  .trace-row {
    display: grid;
    grid-template-columns: 2fr 1.5fr 0.7fr 0.8fr 0.6fr 1fr;
    padding: 14px 16px;
    border-bottom: 1px solid #21262d;
    cursor: pointer;
    transition: background 0.15s;
    width: 100%;
    text-align: left;
    background: transparent;
    border-left: none;
    border-right: none;
    border-top: none;
    color: inherit;
    font-family: inherit;
    font-size: inherit;
  }

  .trace-row:hover {
    background: #21262d;
  }

  .trace-row:last-child {
    border-bottom: none;
  }

  .trace-row.has-errors {
    background: rgba(239, 68, 68, 0.05);
  }

  .trace-row.has-errors:hover {
    background: rgba(239, 68, 68, 0.1);
  }

  .col-trace {
    display: flex;
    flex-direction: column;
    gap: 4px;
    overflow: hidden;
  }

  .trace-id {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 13px;
    color: #58a6ff;
    font-weight: 500;
  }

  .root-message {
    font-size: 12px;
    color: #8b949e;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-services {
    display: flex;
    align-items: center;
  }

  .service-badges {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
  }

  .service-badge {
    padding: 3px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 500;
    color: #fff;
  }

  .more-badge {
    padding: 3px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 500;
    background: #30363d;
    color: #8b949e;
  }

  .col-spans,
  .col-duration,
  .col-errors,
  .col-time {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .span-count {
    font-weight: 600;
    color: #f0f6fc;
  }

  .span-label {
    font-size: 12px;
    color: #8b949e;
  }

  .duration {
    font-weight: 500;
    color: #f0f6fc;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 13px;
  }

  .error-count {
    padding: 4px 10px;
    border-radius: 12px;
    font-size: 12px;
    font-weight: 600;
  }

  .error-count.health-healthy {
    background: rgba(16, 185, 129, 0.15);
    color: #10b981;
  }

  .error-count.health-degraded {
    background: rgba(245, 158, 11, 0.15);
    color: #f59e0b;
  }

  .error-count.health-critical {
    background: rgba(239, 68, 68, 0.15);
    color: #ef4444;
  }

  .timestamp {
    font-size: 12px;
    color: #8b949e;
    font-family: 'SFMono-Regular', Consolas, monospace;
  }
</style>
