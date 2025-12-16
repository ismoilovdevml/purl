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
  let traceSource = 'logs'; // 'spans' or 'logs'

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

  // Check if span is an error (supports both OTLP status and log levels)
  function isSpanError(span) {
    // OTLP status code
    if (span.status_code === 'ERROR') return true;
    // Legacy log level
    if (span.level === 'ERROR' || span.level === 'FATAL') return true;
    return false;
  }

  // Get span kind label
  function getSpanKindLabel(kind) {
    const kinds = {
      'SERVER': 'S',
      'CLIENT': 'C',
      'INTERNAL': 'I',
      'PRODUCER': 'P',
      'CONSUMER': 'K'
    };
    return kinds[kind] || '';
  }

  // Get span kind color
  function getSpanKindColor(kind) {
    const colors = {
      'SERVER': '#10b981',   // green
      'CLIENT': '#3b82f6',   // blue
      'INTERNAL': '#6b7280', // gray
      'PRODUCER': '#f59e0b', // yellow
      'CONSUMER': '#8b5cf6'  // purple
    };
    return colors[kind] || '#6b7280';
  }

  // Filter logs by trace ID
  function filterByTrace(traceId) {
    if (!traceId) return;
    query.set(`trace_id:${traceId}`);
    searchLogs();
  }

  async function loadTrace() {
    if (!traceId) return;

    const traceResult = await fetchTrace(traceId);
    if (traceResult) {
      traceSource = traceResult.source || 'logs';
    }

    timelineLoading = true;
    const timelineData = await fetchTraceTimeline(traceId);
    if (timelineData) {
      traceSource = timelineData.source || 'logs';
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

  // Calculate depth for hierarchy visualization
  function getSpanDepth(span, allSpans) {
    if (!span.parent_span_id) return 0;
    const parent = allSpans.find(s => s.span_id === span.parent_span_id);
    if (!parent) return 0;
    return 1 + getSpanDepth(parent, allSpans);
  }

  // Format attribute value for display
  function formatAttributeValue(value) {
    if (typeof value === 'object') {
      if (value.stringValue !== undefined) return value.stringValue;
      if (value.intValue !== undefined) return value.intValue;
      if (value.boolValue !== undefined) return value.boolValue ? 'true' : 'false';
      return JSON.stringify(value);
    }
    return String(value);
  }

  onMount(() => {
    loadTrace();
    document.addEventListener('keydown', handleKeydown);
  });

  onDestroy(() => {
    document.removeEventListener('keydown', handleKeydown);
  });

  $: if (traceId) loadTrace();
  $: errorCount = timeline ? timeline.filter(isSpanError).length : 0;
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
      <div class="trace-meta">
        <span class="trace-id">{traceId}</span>
        {#if traceSource === 'spans'}
          <span class="source-badge otlp">OTLP</span>
        {:else}
          <span class="source-badge logs">Logs</span>
        {/if}
      </div>
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
  {:else if (timeline && timeline.length > 0) || ($traceData && $traceData.hits && $traceData.hits.length > 0) || ($traceData && $traceData.spans && $traceData.spans.length > 0)}
    <!-- Summary -->
    {#if timeline && timeline.length > 0}
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
          <span class="value" class:error-count={errorCount > 0}>{errorCount}</span>
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
            {@const isError = isSpanError(span)}
            {@const depth = getSpanDepth(span, timeline)}
            <div
              class="span-row"
              class:selected={selectedSpan === span}
              class:error={isError}
              on:click={() => selectSpan(span)}
              on:keydown={(e) => e.key === 'Enter' && selectSpan(span)}
              role="button"
              tabindex="0"
            >
              <div class="span-info" style="padding-left: {depth * 16}px">
                <span class="span-index">{index + 1}</span>
                {#if span.span_kind}
                  <span
                    class="span-kind-badge"
                    style="background-color: {getSpanKindColor(span.span_kind)}"
                    title={span.span_kind}
                  >
                    {getSpanKindLabel(span.span_kind)}
                  </span>
                {/if}
                <span
                  class="service-badge"
                  style="background-color: {getServiceColor(span.service)}"
                >
                  {span.service}
                </span>
                {#if span.operation}
                  <span class="operation" title={span.operation}>{span.operation}</span>
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
              {#if span.status_code && span.status_code !== 'UNSET'}
                <span class="status-indicator" class:status-ok={span.status_code === 'OK'} class:status-error={span.status_code === 'ERROR'}>
                  {span.status_code}
                </span>
              {/if}
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
            {#if selectedSpan.span_kind}
              <div class="detail-item">
                <span class="label">Span Kind</span>
                <span class="value">{selectedSpan.span_kind}</span>
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
            {#if selectedSpan.end_time}
              <div class="detail-item">
                <span class="label">End Time</span>
                <span class="value">{selectedSpan.end_time}</span>
              </div>
            {/if}
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
            {#if selectedSpan.status_code}
              <div class="detail-item">
                <span class="label">Status</span>
                <span class="value status-{selectedSpan.status_code?.toLowerCase()}">{selectedSpan.status_code}</span>
              </div>
            {/if}
            {#if selectedSpan.status_message}
              <div class="detail-item full-width">
                <span class="label">Status Message</span>
                <span class="value">{selectedSpan.status_message}</span>
              </div>
            {/if}
            {#if selectedSpan.level}
              <div class="detail-item">
                <span class="label">Level</span>
                <span class="value level-{selectedSpan.level?.toLowerCase()}">{selectedSpan.level}</span>
              </div>
            {/if}
          </div>

          <!-- Span Attributes -->
          {#if selectedSpan.attributes && selectedSpan.attributes.length > 0}
            <div class="attributes-section">
              <h5>Attributes</h5>
              <div class="attributes-list">
                {#each selectedSpan.attributes as attr}
                  <div class="attribute-item">
                    <span class="attr-key">{attr.key}</span>
                    <span class="attr-value">{formatAttributeValue(attr.value)}</span>
                  </div>
                {/each}
              </div>
            </div>
          {/if}

          <!-- Span Events -->
          {#if selectedSpan.events && selectedSpan.events.length > 0}
            <div class="events-section">
              <h5>Events</h5>
              <div class="events-list">
                {#each selectedSpan.events as event}
                  <div class="event-item">
                    <span class="event-name">{event.name}</span>
                    {#if event.timeUnixNano}
                      <span class="event-time">{formatTime(new Date(event.timeUnixNano / 1000000))}</span>
                    {/if}
                  </div>
                {/each}
              </div>
            </div>
          {/if}
        </div>
      {/if}
    {:else if $traceData && ($traceData.hits || $traceData.spans)}
      <!-- Show summary from traceData when timeline is not available -->
      <div class="trace-summary">
        <div class="summary-item">
          <span class="label">{$traceData.spans ? 'Spans' : 'Log Entries'}</span>
          <span class="value">{$traceData.spans?.length || $traceData.hits?.length || 0}</span>
        </div>
        <div class="summary-item">
          <span class="label">Services</span>
          <span class="value">{new Set(($traceData.spans || $traceData.hits || []).map(h => h.service)).size}</span>
        </div>
      </div>
    {/if}

    <!-- Always show trace logs if available -->
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

  .trace-meta {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .trace-id {
    font-family: monospace;
    font-size: 12px;
    color: var(--text-secondary, #888);
  }

  .source-badge {
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .source-badge.otlp {
    background: #10b981;
    color: #fff;
  }

  .source-badge.logs {
    background: #6b7280;
    color: #fff;
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
    padding-left: 240px;
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
    gap: 6px;
    width: 240px;
    flex-shrink: 0;
  }

  .span-index {
    font-size: 11px;
    color: var(--text-secondary, #888);
    width: 20px;
  }

  .span-kind-badge {
    width: 18px;
    height: 18px;
    border-radius: 3px;
    font-size: 10px;
    font-weight: 600;
    color: #fff;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .service-badge {
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 500;
    color: #fff;
    max-width: 100px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .operation {
    font-size: 12px;
    color: var(--text-secondary, #888);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
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

  .status-indicator {
    margin-left: 8px;
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 10px;
    font-weight: 600;
    flex-shrink: 0;
  }

  .status-ok {
    background: #10b981;
    color: #fff;
  }

  .status-error {
    background: #ef4444;
    color: #fff;
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

  .span-details h5 {
    margin: 16px 0 8px 0;
    font-size: 12px;
    color: var(--text-secondary, #888);
    text-transform: uppercase;
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

  .detail-item.full-width {
    grid-column: 1 / -1;
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

  .status-ok {
    color: #10b981;
  }

  .status-error {
    color: #ef4444;
  }

  .status-unset {
    color: var(--text-secondary, #888);
  }

  .attributes-section,
  .events-section {
    margin-top: 12px;
    padding-top: 12px;
    border-top: 1px solid var(--border-color, #363646);
  }

  .attributes-list,
  .events-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .attribute-item {
    display: flex;
    gap: 8px;
    font-size: 12px;
  }

  .attr-key {
    color: var(--text-secondary, #888);
    min-width: 150px;
  }

  .attr-value {
    color: var(--text-primary, #fff);
    font-family: monospace;
    word-break: break-all;
  }

  .event-item {
    display: flex;
    gap: 8px;
    font-size: 12px;
  }

  .event-name {
    color: var(--text-primary, #fff);
  }

  .event-time {
    color: var(--text-secondary, #888);
    font-family: monospace;
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
