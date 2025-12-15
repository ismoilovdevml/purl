<script>
  import { onMount, onDestroy } from 'svelte';
  import {
    traceData,
    traceLoading,
    traceError,
    fetchTrace,
    fetchTraceTimeline,
    getServiceColor,
    formatDuration,
    formatTimestamp,
    processTimelineData,
    getBarPosition
  } from '../stores/traces.js';
  import { query, searchLogs } from '../stores/logs.js';

  export let traceId = null;
  export let onClose = () => {};

  let timeline = null;
  let timelineLoading = false;
  let selectedSpan = null;
  let minTime = 0;
  let maxTime = 0;
  let totalDuration = 0;

  // Format time for display
  function formatTime(ts) {
    return formatTimestamp(ts);
  }

  // Get bar style for waterfall
  function getBarStyle(span) {
    const pos = getBarPosition(span, minTime, totalDuration);
    return {
      left: `${pos.left}%`,
      width: `${pos.width}%`
    };
  }

  // Filter logs by trace ID
  function filterByTrace(traceId) {
    if (!traceId) return;
    query.set(`trace_id:${traceId}`);
    searchLogs();
  }

  async function loadTrace() {
    if (!traceId) return;

    await fetchTrace(traceId);

    timelineLoading = true;
    const timelineData = await fetchTraceTimeline(traceId);
    if (timelineData) {
      const processed = processTimelineData(timelineData);
      timeline = processed.spans;
      minTime = processed.minTime;
      maxTime = processed.maxTime;
      totalDuration = processed.totalDuration;
    }
    timelineLoading = false;
  }

  function selectSpan(span) {
    selectedSpan = selectedSpan === span ? null : span;
  }

  function handleKeydown(event) {
    if (event.key === 'Escape') {
      onClose();
    }
  }

  onMount(() => {
    loadTrace();
    document.addEventListener('keydown', handleKeydown);
  });

  onDestroy(() => {
    document.removeEventListener('keydown', handleKeydown);
  });

  $: if (traceId) loadTrace();
</script>

<div class="trace-view">
  {#if !traceId}
    <div class="no-trace-selected">
      <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
        <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
      </svg>
      <h3>No Trace Selected</h3>
      <p>Select a log entry with a trace ID from the Logs page to view trace details.</p>
      <p class="hint">Click on a log row that has a trace_id to see the full distributed trace.</p>
    </div>
  {:else}
  <div class="trace-header">
    <div class="trace-title">
      <h3>Trace Details</h3>
      <span class="trace-id">{traceId}</span>
    </div>
    <div class="trace-actions">
      <button class="btn-secondary" on:click={() => filterByTrace(traceId)}>
        Filter Logs
      </button>
      <button class="btn-close" on:click={onClose} aria-label="Close trace view">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <line x1="18" y1="6" x2="6" y2="18"></line>
          <line x1="6" y1="6" x2="18" y2="18"></line>
        </svg>
      </button>
    </div>
  </div>

  {#if $traceLoading || timelineLoading}
    <div class="loading">
      <div class="spinner"></div>
      <span>Loading trace data...</span>
    </div>
  {:else if $traceError}
    <div class="error">
      <span>Error: {$traceError}</span>
    </div>
  {:else if timeline && timeline.length > 0}
    <div class="trace-summary">
      <div class="summary-item">
        <span class="label">Services</span>
        <span class="value">{new Set(timeline.map(s => s.service)).size}</span>
      </div>
      <div class="summary-item">
        <span class="label">Spans</span>
        <span class="value">{timeline.length}</span>
      </div>
      <div class="summary-item">
        <span class="label">Duration</span>
        <span class="value">{formatDuration(totalDuration)}</span>
      </div>
      <div class="summary-item">
        <span class="label">Errors</span>
        <span class="value error-count">{timeline.filter(s => s.level === 'ERROR' || s.level === 'FATAL').length}</span>
      </div>
    </div>

    <div class="timeline-container">
      <div class="timeline-header">
        <div class="time-axis">
          <span class="time-label">{formatTime(new Date(minTime))}</span>
          <span class="time-label">{formatTime(new Date((minTime + maxTime) / 2))}</span>
          <span class="time-label">{formatTime(new Date(maxTime))}</span>
        </div>
      </div>

      <div class="waterfall">
        {#each timeline as span, index}
          {@const barStyle = getBarStyle(span)}
          {@const isError = span.level === 'ERROR' || span.level === 'FATAL'}
          <div
            class="span-row"
            class:selected={selectedSpan === span}
            class:error={isError}
            on:click={() => selectSpan(span)}
            on:keydown={(e) => e.key === 'Enter' && selectSpan(span)}
            role="button"
            tabindex="0"
          >
            <div class="span-info">
              <span class="span-index">{index + 1}</span>
              <span
                class="service-badge"
                style="background-color: {getServiceColor(span.service)}"
              >
                {span.service}
              </span>
              {#if span.operation}
                <span class="operation">{span.operation}</span>
              {/if}
            </div>
            <div class="span-bar-container">
              <div
                class="span-bar"
                class:error-bar={isError}
                style="left: {barStyle.left}; width: {barStyle.width}; background-color: {isError ? '#ef4444' : getServiceColor(span.service)}"
              >
                <span class="duration-label">{formatDuration(span.duration_ms || 0)}</span>
              </div>
            </div>
          </div>
        {/each}
      </div>
    </div>

    {#if selectedSpan}
      <div class="span-details">
        <h4>Span Details</h4>
        <div class="details-grid">
          <div class="detail-item">
            <span class="label">Service</span>
            <span class="value">{selectedSpan.service}</span>
          </div>
          {#if selectedSpan.operation}
            <div class="detail-item">
              <span class="label">Operation</span>
              <span class="value">{selectedSpan.operation}</span>
            </div>
          {/if}
          <div class="detail-item">
            <span class="label">Duration</span>
            <span class="value">{formatDuration(selectedSpan.duration_ms || 0)}</span>
          </div>
          <div class="detail-item">
            <span class="label">Start Time</span>
            <span class="value">{selectedSpan.start_time || 'N/A'}</span>
          </div>
          {#if selectedSpan.span_id}
            <div class="detail-item">
              <span class="label">Span ID</span>
              <span class="value mono">{selectedSpan.span_id}</span>
            </div>
          {/if}
          {#if selectedSpan.parent_span_id}
            <div class="detail-item">
              <span class="label">Parent Span</span>
              <span class="value mono">{selectedSpan.parent_span_id}</span>
            </div>
          {/if}
          <div class="detail-item">
            <span class="label">Level</span>
            <span class="value level-{selectedSpan.level?.toLowerCase()}">{selectedSpan.level || 'INFO'}</span>
          </div>
        </div>
      </div>
    {/if}

    {#if $traceData && $traceData.hits && $traceData.hits.length > 0}
      <div class="trace-logs">
        <h4>Trace Logs ({$traceData.hits.length})</h4>
        <div class="logs-list">
          {#each $traceData.hits as log}
            <div class="log-entry" class:error={log.level === 'ERROR' || log.level === 'FATAL'}>
              <span class="log-time">{formatTime(log.timestamp)}</span>
              <span
                class="log-service"
                style="background-color: {getServiceColor(log.service)}"
              >
                {log.service}
              </span>
              <span class="log-level level-{log.level?.toLowerCase()}">{log.level}</span>
              <span class="log-message">{log.message}</span>
            </div>
          {/each}
        </div>
      </div>
    {/if}
  {:else}
    <div class="empty">
      <span>No trace data found for this trace ID</span>
    </div>
  {/if}
  {/if}
</div>

<style>
  .trace-view {
    background: var(--bg-secondary, #1e1e2e);
    border-radius: 8px;
    padding: 16px;
    max-height: 80vh;
    overflow-y: auto;
  }

  .no-trace-selected {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 60px 20px;
    text-align: center;
    color: var(--text-secondary, #888);
  }

  .no-trace-selected svg {
    margin-bottom: 20px;
    opacity: 0.5;
  }

  .no-trace-selected h3 {
    margin: 0 0 12px 0;
    font-size: 20px;
    color: var(--text-primary, #fff);
  }

  .no-trace-selected p {
    margin: 0 0 8px 0;
    font-size: 14px;
    max-width: 400px;
  }

  .no-trace-selected .hint {
    font-size: 12px;
    opacity: 0.7;
  }

  .trace-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--border-color, #363646);
  }

  .trace-title h3 {
    margin: 0 0 4px 0;
    font-size: 18px;
    color: var(--text-primary, #fff);
  }

  .trace-id {
    font-family: monospace;
    font-size: 12px;
    color: var(--text-secondary, #888);
  }

  .trace-actions {
    display: flex;
    gap: 8px;
  }

  .btn-secondary {
    padding: 6px 12px;
    border: 1px solid var(--border-color, #363646);
    background: transparent;
    color: var(--text-primary, #fff);
    border-radius: 4px;
    cursor: pointer;
    font-size: 13px;
  }

  .btn-secondary:hover {
    background: var(--bg-hover, #2a2a3a);
  }

  .btn-close {
    padding: 4px;
    border: none;
    background: transparent;
    color: var(--text-secondary, #888);
    cursor: pointer;
    border-radius: 4px;
  }

  .btn-close:hover {
    color: var(--text-primary, #fff);
    background: var(--bg-hover, #2a2a3a);
  }

  .loading, .error, .empty {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 12px;
    padding: 40px;
    color: var(--text-secondary, #888);
  }

  .error {
    color: #ef4444;
  }

  .spinner {
    width: 24px;
    height: 24px;
    border: 2px solid var(--border-color, #363646);
    border-top-color: var(--accent-color, #3b82f6);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .trace-summary {
    display: flex;
    gap: 24px;
    margin-bottom: 16px;
    padding: 12px;
    background: var(--bg-tertiary, #252535);
    border-radius: 6px;
  }

  .summary-item {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .summary-item .label {
    font-size: 11px;
    color: var(--text-secondary, #888);
    text-transform: uppercase;
  }

  .summary-item .value {
    font-size: 18px;
    font-weight: 600;
    color: var(--text-primary, #fff);
  }

  .error-count {
    color: #ef4444;
  }

  .timeline-container {
    margin-bottom: 16px;
  }

  .timeline-header {
    padding: 8px 0;
    border-bottom: 1px solid var(--border-color, #363646);
  }

  .time-axis {
    display: flex;
    justify-content: space-between;
    padding-left: 200px;
  }

  .time-label {
    font-size: 11px;
    color: var(--text-secondary, #888);
    font-family: monospace;
  }

  .waterfall {
    padding-top: 8px;
  }

  .span-row {
    display: flex;
    align-items: center;
    padding: 8px 0;
    border-bottom: 1px solid var(--border-color, #363646);
    cursor: pointer;
    transition: background 0.15s;
  }

  .span-row:hover {
    background: var(--bg-hover, #2a2a3a);
  }

  .span-row.selected {
    background: var(--bg-selected, #2a2a4a);
  }

  .span-row.error {
    background: rgba(239, 68, 68, 0.1);
  }

  .span-info {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 200px;
    flex-shrink: 0;
  }

  .span-index {
    font-size: 11px;
    color: var(--text-secondary, #888);
    width: 24px;
  }

  .service-badge {
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 500;
    color: #fff;
  }

  .operation {
    font-size: 12px;
    color: var(--text-secondary, #888);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .span-bar-container {
    flex: 1;
    height: 24px;
    position: relative;
    background: var(--bg-tertiary, #252535);
    border-radius: 4px;
  }

  .span-bar {
    position: absolute;
    height: 100%;
    border-radius: 4px;
    display: flex;
    align-items: center;
    padding: 0 8px;
    min-width: 40px;
    transition: opacity 0.15s;
  }

  .span-bar:hover {
    opacity: 0.9;
  }

  .error-bar {
    background-color: #ef4444 !important;
  }

  .duration-label {
    font-size: 11px;
    font-weight: 500;
    color: #fff;
    white-space: nowrap;
  }

  .span-details {
    margin-top: 16px;
    padding: 16px;
    background: var(--bg-tertiary, #252535);
    border-radius: 6px;
  }

  .span-details h4 {
    margin: 0 0 12px 0;
    font-size: 14px;
    color: var(--text-primary, #fff);
  }

  .details-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 12px;
  }

  .detail-item {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .detail-item .label {
    font-size: 11px;
    color: var(--text-secondary, #888);
    text-transform: uppercase;
  }

  .detail-item .value {
    font-size: 13px;
    color: var(--text-primary, #fff);
  }

  .detail-item .value.mono {
    font-family: monospace;
    font-size: 12px;
  }

  .trace-logs {
    margin-top: 16px;
  }

  .trace-logs h4 {
    margin: 0 0 12px 0;
    font-size: 14px;
    color: var(--text-primary, #fff);
  }

  .logs-list {
    max-height: 300px;
    overflow-y: auto;
    border: 1px solid var(--border-color, #363646);
    border-radius: 6px;
  }

  .log-entry {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    border-bottom: 1px solid var(--border-color, #363646);
    font-size: 12px;
  }

  .log-entry:last-child {
    border-bottom: none;
  }

  .log-entry.error {
    background: rgba(239, 68, 68, 0.1);
  }

  .log-time {
    font-family: monospace;
    color: var(--text-secondary, #888);
    flex-shrink: 0;
  }

  .log-service {
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 10px;
    font-weight: 500;
    color: #fff;
    flex-shrink: 0;
  }

  .log-level {
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 10px;
    font-weight: 500;
    flex-shrink: 0;
  }

  .level-error, .level-fatal {
    background: #ef4444;
    color: #fff;
  }

  .level-warn, .level-warning {
    background: #f59e0b;
    color: #000;
  }

  .level-info {
    background: #3b82f6;
    color: #fff;
  }

  .level-debug {
    background: #6b7280;
    color: #fff;
  }

  .level-trace {
    background: #4b5563;
    color: #fff;
  }

  .log-message {
    flex: 1;
    color: var(--text-primary, #fff);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
