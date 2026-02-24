<!--
  TracesPage Component
  Trace exploration page with search, timeline visualization, and logs table.
  Supports searching by trace_id or request_id.

  API endpoints:
  - GET /api/traces/:trace_id — returns { logs, trace_id, total }
  - GET /api/traces/:trace_id/timeline — returns { timeline: { services, spans, duration_ms } }
  - GET /api/requests/:request_id — returns { logs, request_id, total }
-->
<script>
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import LoadingSpinner from './ui/LoadingSpinner.svelte';
  import Badge from './ui/Badge.svelte';
  import { success as toastSuccess, error as toastError } from '../stores/toast.js';
  import { formatTimestamp, formatFullTimestamp } from '../utils/format.js';

  const API_BASE = '/api';

  // Service colors for timeline visualization
  const SERVICE_COLORS = [
    '#58a6ff', '#3fb950', '#d29922', '#f78166', '#a371f7',
    '#79c0ff', '#7ee787', '#e3b341', '#ffa657', '#d2a8ff',
    '#56d4dd', '#f0883e', '#bc8cff', '#39d353', '#db6d28',
  ];

  let searchQuery = '';
  let searchType = 'trace'; // 'trace' or 'request'
  let loading = false;
  let logs = [];
  let timeline = null;
  let traceId = '';
  let requestId = '';
  let total = 0;
  let errorMsg = '';
  let hasSearched = false;
  let expandedLogIndex = -1;

  // Color assignment map for services
  let serviceColorMap = {};

  function getServiceColor(service) {
    if (!serviceColorMap[service]) {
      const idx = Object.keys(serviceColorMap).length % SERVICE_COLORS.length;
      serviceColorMap[service] = SERVICE_COLORS[idx];
    }
    return serviceColorMap[service];
  }

  function detectSearchType(query) {
    const trimmed = query.trim();
    // Simple heuristic: request IDs tend to be shorter UUIDs or numeric,
    // trace IDs are typically longer hex strings (32 chars) or have specific prefixes
    if (trimmed.startsWith('req-') || trimmed.startsWith('req_')) {
      return 'request';
    }
    return 'trace';
  }

  async function handleSearch() {
    const query = searchQuery.trim();
    if (!query) {
      toastError('Please enter a trace ID or request ID');
      return;
    }

    loading = true;
    errorMsg = '';
    logs = [];
    timeline = null;
    traceId = '';
    requestId = '';
    total = 0;
    hasSearched = true;
    expandedLogIndex = -1;
    serviceColorMap = {};

    const detectedType = detectSearchType(query);

    try {
      if (detectedType === 'request') {
        // Fetch request logs
        const res = await fetch(`${API_BASE}/requests/${encodeURIComponent(query)}`);
        if (!res.ok) {
          const errData = await res.json().catch(() => ({}));
          throw new Error(errData.error || `Request not found (${res.status})`);
        }
        const data = await res.json();
        logs = data.logs || [];
        requestId = data.request_id || query;
        total = data.total || logs.length;
        searchType = 'request';
      } else {
        // Fetch trace logs and timeline in parallel
        const [logsRes, timelineRes] = await Promise.all([
          fetch(`${API_BASE}/traces/${encodeURIComponent(query)}`),
          fetch(`${API_BASE}/traces/${encodeURIComponent(query)}/timeline`),
        ]);

        if (!logsRes.ok) {
          const errData = await logsRes.json().catch(() => ({}));
          throw new Error(errData.error || `Trace not found (${logsRes.status})`);
        }

        const logsData = await logsRes.json();
        logs = logsData.logs || [];
        traceId = logsData.trace_id || query;
        total = logsData.total || logs.length;
        searchType = 'trace';

        if (timelineRes.ok) {
          const timelineData = await timelineRes.json();
          timeline = timelineData.timeline || null;
        }
      }

      if (logs.length === 0) {
        errorMsg = `No logs found for ${detectedType === 'request' ? 'request' : 'trace'} "${query}"`;
      } else {
        toastSuccess(`Found ${total} log${total !== 1 ? 's' : ''}`);
      }
    } catch (err) {
      errorMsg = err.message || 'Failed to fetch trace data';
      toastError(errorMsg);
    } finally {
      loading = false;
    }
  }

  function handleKeydown(event) {
    if (event.detail?.key === 'Enter' || event.key === 'Enter') {
      handleSearch();
    }
  }

  function toggleLogExpand(index) {
    expandedLogIndex = expandedLogIndex === index ? -1 : index;
  }

  function getLevelVariant(level) {
    const l = (level || '').toLowerCase();
    if (l === 'error' || l === 'fatal' || l === 'critical') return 'error';
    if (l === 'warn' || l === 'warning') return 'warning';
    if (l === 'info') return 'primary';
    if (l === 'debug' || l === 'trace') return 'default';
    return 'default';
  }

  function formatDuration(ms) {
    if (ms === null || ms === undefined) return '-';
    if (ms < 1) return `${(ms * 1000).toFixed(0)}us`;
    if (ms < 1000) return `${ms.toFixed(1)}ms`;
    if (ms < 60000) return `${(ms / 1000).toFixed(2)}s`;
    return `${(ms / 60000).toFixed(1)}min`;
  }

  // Compute stats from logs
  $: uniqueServices = [...new Set(logs.map(l => l.service).filter(Boolean))];
  $: totalDuration = timeline?.duration_ms || 0;
  $: levelCounts = logs.reduce((acc, l) => {
    const level = (l.level || 'unknown').toLowerCase();
    acc[level] = (acc[level] || 0) + 1;
    return acc;
  }, {});
  $: hasErrors = (levelCounts['error'] || 0) + (levelCounts['fatal'] || 0) + (levelCounts['critical'] || 0) > 0;

  // Compute timeline span positions
  $: timelineSpans = (() => {
    if (!timeline?.spans || !timeline?.duration_ms) return [];
    const dur = timeline.duration_ms;
    if (dur === 0) return [];
    return timeline.spans.map(span => ({
      ...span,
      leftPct: ((span.start_ms || 0) / dur) * 100,
      widthPct: Math.max(((span.duration_ms || 0) / dur) * 100, 0.5),
      color: getServiceColor(span.service),
    }));
  })();

  // Group spans by service for timeline rows
  $: timelineRows = (() => {
    if (!timelineSpans.length) return [];
    const serviceMap = new Map();
    for (const span of timelineSpans) {
      const svc = span.service || 'unknown';
      if (!serviceMap.has(svc)) {
        serviceMap.set(svc, []);
      }
      serviceMap.get(svc).push(span);
    }
    return Array.from(serviceMap.entries()).map(([service, spans]) => ({
      service,
      spans,
      color: getServiceColor(service),
    }));
  })();
</script>

<div class="traces-page">
  <!-- Header -->
  <header class="page-header">
    <div class="header-left">
      <h1>Traces</h1>
      {#if hasSearched && !loading && logs.length > 0}
        <Badge variant={hasErrors ? 'error' : 'success'} pill>
          {total} log{total !== 1 ? 's' : ''}
        </Badge>
      {/if}
    </div>
  </header>

  <!-- Search Bar -->
  <div class="search-section">
    <div class="search-bar">
      <div class="search-input-wrapper">
        <Input
          bind:value={searchQuery}
          placeholder="Enter trace ID or request ID (e.g. abc123-def456-...)"
          size="md"
          fullWidth
          on:keydown={handleKeydown}
        >
          <svg slot="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="11" cy="11" r="8"/>
            <line x1="21" y1="21" x2="16.65" y2="16.65"/>
          </svg>
        </Input>
      </div>
      <Button variant="primary" on:click={handleSearch} loading={loading}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="11" cy="11" r="8"/>
          <line x1="21" y1="21" x2="16.65" y2="16.65"/>
        </svg>
        Search
      </Button>
    </div>
    <div class="search-hint">
      Search by trace ID to see the full distributed trace, or by request ID to see logs from a single request.
    </div>
  </div>

  <!-- Content Area -->
  <div class="content">
    {#if loading}
      <div class="loading-container">
        <LoadingSpinner size="lg" label="Searching for trace..." centered />
      </div>
    {:else if errorMsg && logs.length === 0}
      <div class="empty-state">
        <div class="empty-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
            <line x1="12" y1="9" x2="12" y2="13"/>
            <line x1="12" y1="17" x2="12.01" y2="17"/>
          </svg>
        </div>
        <p class="empty-title">{errorMsg}</p>
        <p class="empty-sub">Check the ID and try again.</p>
      </div>
    {:else if !hasSearched}
      <div class="empty-state">
        <div class="empty-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
          </svg>
        </div>
        <p class="empty-title">Explore Distributed Traces</p>
        <p class="empty-sub">Enter a trace ID or request ID above to visualize the request flow across services.</p>
      </div>
    {:else}
      <!-- Stats Summary -->
      <div class="stats-bar">
        <div class="stat-item">
          <span class="stat-label">ID</span>
          <span class="stat-value mono">{traceId || requestId}</span>
        </div>
        <div class="stat-item">
          <span class="stat-label">Type</span>
          <span class="stat-value">{searchType === 'trace' ? 'Trace' : 'Request'}</span>
        </div>
        <div class="stat-item">
          <span class="stat-label">Logs</span>
          <span class="stat-value">{total}</span>
        </div>
        <div class="stat-item">
          <span class="stat-label">Services</span>
          <span class="stat-value">{uniqueServices.length}</span>
        </div>
        {#if totalDuration > 0}
          <div class="stat-item">
            <span class="stat-label">Duration</span>
            <span class="stat-value">{formatDuration(totalDuration)}</span>
          </div>
        {/if}
        {#each Object.entries(levelCounts) as [level, count]}
          <div class="stat-item">
            <Badge variant={getLevelVariant(level)} size="sm" pill>{level}: {count}</Badge>
          </div>
        {/each}
      </div>

      <!-- Timeline Visualization -->
      {#if timelineRows.length > 0}
        <div class="timeline-section">
          <div class="section-header">
            <h2>Timeline</h2>
            <span class="section-meta">{formatDuration(totalDuration)} total</span>
          </div>
          <div class="timeline-container">
            <!-- Time axis -->
            <div class="timeline-axis">
              <span class="axis-label">0ms</span>
              <span class="axis-label">{formatDuration(totalDuration * 0.25)}</span>
              <span class="axis-label">{formatDuration(totalDuration * 0.5)}</span>
              <span class="axis-label">{formatDuration(totalDuration * 0.75)}</span>
              <span class="axis-label">{formatDuration(totalDuration)}</span>
            </div>

            <!-- Service rows -->
            {#each timelineRows as row}
              <div class="timeline-row">
                <div class="timeline-service">
                  <span class="service-dot" style="background: {row.color}"></span>
                  <span class="service-name">{row.service}</span>
                </div>
                <div class="timeline-track">
                  <!-- Grid lines -->
                  <div class="grid-line" style="left: 25%"></div>
                  <div class="grid-line" style="left: 50%"></div>
                  <div class="grid-line" style="left: 75%"></div>

                  {#each row.spans as span}
                    <div
                      class="timeline-span"
                      style="left: {span.leftPct}%; width: {span.widthPct}%; background: {span.color};"
                      title="{span.operation || span.service}: {formatDuration(span.duration_ms)} ({formatDuration(span.start_ms)} - {formatDuration((span.start_ms || 0) + (span.duration_ms || 0))})"
                    >
                      {#if span.widthPct > 8}
                        <span class="span-label">{span.operation || ''}</span>
                      {/if}
                    </div>
                  {/each}
                </div>
              </div>
            {/each}
          </div>
        </div>
      {/if}

      <!-- Logs Table -->
      {#if logs.length > 0}
        <div class="logs-section">
          <div class="section-header">
            <h2>Logs</h2>
            <span class="section-meta">{logs.length} entries</span>
          </div>
          <div class="logs-table-wrapper">
            <table class="logs-table">
              <thead>
                <tr>
                  <th class="col-timestamp">Timestamp</th>
                  <th class="col-service">Service</th>
                  <th class="col-level">Level</th>
                  <th class="col-message">Message</th>
                </tr>
              </thead>
              <tbody>
                {#each logs as log, i}
                  <tr
                    class="log-row"
                    class:log-error={(log.level || '').toLowerCase() === 'error' || (log.level || '').toLowerCase() === 'fatal'}
                    class:log-warn={(log.level || '').toLowerCase() === 'warn' || (log.level || '').toLowerCase() === 'warning'}
                    class:expanded={expandedLogIndex === i}
                    on:click={() => toggleLogExpand(i)}
                  >
                    <td class="col-timestamp">
                      <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
                        {formatTimestamp(log.timestamp)}
                      </span>
                    </td>
                    <td class="col-service">
                      {#if log.service}
                        <span class="service-tag" style="border-color: {getServiceColor(log.service)}; color: {getServiceColor(log.service)}">
                          {log.service}
                        </span>
                      {:else}
                        <span class="muted">-</span>
                      {/if}
                    </td>
                    <td class="col-level">
                      <Badge variant={getLevelVariant(log.level)} size="sm">
                        {(log.level || 'unknown').toUpperCase()}
                      </Badge>
                    </td>
                    <td class="col-message">
                      <span class="message-text">{log.message || log.msg || '-'}</span>
                    </td>
                  </tr>
                  {#if expandedLogIndex === i}
                    <tr class="log-detail-row">
                      <td colspan="4">
                        <div class="log-detail">
                          <pre class="log-json">{JSON.stringify(log, null, 2)}</pre>
                        </div>
                      </td>
                    </tr>
                  {/if}
                {/each}
              </tbody>
            </table>
          </div>
        </div>
      {/if}
    {/if}
  </div>
</div>

<style>
  .traces-page {
    padding: 16px 20px;
    overflow-y: auto;
    height: calc(100vh - 60px);
    display: flex;
    flex-direction: column;
  }

  /* Header */
  .page-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
    flex-shrink: 0;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  h1 {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  /* Search Section */
  .search-section {
    flex-shrink: 0;
    margin-bottom: 16px;
  }

  .search-bar {
    display: flex;
    gap: 8px;
    align-items: stretch;
  }

  .search-input-wrapper {
    flex: 1;
  }

  .search-hint {
    font-size: 0.6875rem;
    color: #6e7681;
    margin-top: 6px;
  }

  /* Content */
  .content {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
  }

  /* Loading / Empty */
  .loading-container {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 300px;
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 300px;
    text-align: center;
    padding: 40px 20px;
  }

  .empty-icon {
    width: 48px;
    height: 48px;
    color: #30363d;
    margin-bottom: 16px;
  }

  .empty-icon svg {
    width: 100%;
    height: 100%;
  }

  .empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: #c9d1d9;
    margin: 0 0 6px 0;
  }

  .empty-sub {
    font-size: 0.8125rem;
    color: #6e7681;
    margin: 0;
    max-width: 400px;
  }

  /* Stats Bar */
  .stats-bar {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    padding: 10px 14px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    margin-bottom: 16px;
    align-items: center;
    flex-shrink: 0;
  }

  .stat-item {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .stat-label {
    font-size: 0.6875rem;
    color: #6e7681;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .stat-value.mono {
    font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
    font-size: 0.75rem;
    color: #58a6ff;
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* Section Headers */
  .section-header {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
  }

  h2 {
    font-size: 0.75rem;
    font-weight: 600;
    color: #8b949e;
    margin: 0;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .section-meta {
    font-size: 0.6875rem;
    color: #6e7681;
  }

  /* Timeline */
  .timeline-section {
    margin-bottom: 20px;
    flex-shrink: 0;
  }

  .timeline-container {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 12px 16px;
    overflow-x: auto;
  }

  .timeline-axis {
    display: flex;
    justify-content: space-between;
    padding-left: 140px;
    margin-bottom: 8px;
    border-bottom: 1px solid #21262d;
    padding-bottom: 6px;
  }

  .axis-label {
    font-size: 0.625rem;
    color: #6e7681;
    font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
  }

  .timeline-row {
    display: flex;
    align-items: center;
    height: 32px;
    gap: 0;
  }

  .timeline-row:not(:last-child) {
    border-bottom: 1px solid #21262d;
  }

  .timeline-service {
    width: 140px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 8px;
    padding-right: 12px;
  }

  .service-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .service-name {
    font-size: 0.75rem;
    color: #c9d1d9;
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .timeline-track {
    flex: 1;
    position: relative;
    height: 100%;
    min-width: 400px;
  }

  .grid-line {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 1px;
    background: #21262d;
  }

  .timeline-span {
    position: absolute;
    top: 6px;
    height: 20px;
    border-radius: 3px;
    opacity: 0.85;
    cursor: pointer;
    transition: opacity 0.15s, transform 0.15s;
    display: flex;
    align-items: center;
    overflow: hidden;
    min-width: 2px;
  }

  .timeline-span:hover {
    opacity: 1;
    transform: scaleY(1.15);
    z-index: 2;
  }

  .span-label {
    font-size: 0.625rem;
    color: #fff;
    padding: 0 4px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-weight: 500;
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
  }

  /* Logs Table */
  .logs-section {
    flex: 1;
  }

  .logs-table-wrapper {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
  }

  .logs-table {
    width: 100%;
    border-collapse: collapse;
    table-layout: fixed;
  }

  .logs-table thead {
    position: sticky;
    top: 0;
    z-index: 1;
  }

  .logs-table th {
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

  .logs-table td {
    padding: 6px 12px;
    font-size: 0.8125rem;
    color: #c9d1d9;
    border-bottom: 1px solid #21262d;
    vertical-align: middle;
  }

  .col-timestamp {
    width: 110px;
  }

  .col-service {
    width: 120px;
  }

  .col-level {
    width: 80px;
  }

  .col-message {
    /* takes remaining space */
  }

  .log-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .log-row:hover {
    background: rgba(88, 166, 255, 0.04);
  }

  .log-row.expanded {
    background: rgba(88, 166, 255, 0.06);
  }

  .log-row.log-error {
    background: rgba(248, 81, 73, 0.04);
  }

  .log-row.log-error:hover {
    background: rgba(248, 81, 73, 0.08);
  }

  .log-row.log-warn {
    background: rgba(210, 153, 34, 0.03);
  }

  .log-row.log-warn:hover {
    background: rgba(210, 153, 34, 0.06);
  }

  .timestamp {
    font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
    font-size: 0.75rem;
    color: #8b949e;
  }

  .service-tag {
    display: inline-block;
    padding: 1px 6px;
    font-size: 0.6875rem;
    font-weight: 500;
    border: 1px solid;
    border-radius: 4px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 100%;
  }

  .muted {
    color: #6e7681;
  }

  .message-text {
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
    font-size: 0.75rem;
  }

  /* Expanded log detail */
  .log-detail-row td {
    padding: 0;
    background: #0d1117;
  }

  .log-detail {
    padding: 12px 16px;
  }

  .log-json {
    margin: 0;
    font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
    font-size: 0.75rem;
    color: #c9d1d9;
    line-height: 1.5;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 300px;
    overflow-y: auto;
    background: #0d1117;
    border-radius: 4px;
  }

  /* Responsive */
  @media (max-width: 900px) {
    .timeline-service {
      width: 100px;
    }

    .stats-bar {
      gap: 10px;
    }

    .stat-value.mono {
      max-width: 140px;
    }

    .col-timestamp {
      width: 90px;
    }

    .col-service {
      width: 90px;
    }
  }

  @media (max-width: 640px) {
    .traces-page {
      padding: 12px 14px;
    }

    .search-bar {
      flex-direction: column;
    }

    .timeline-axis {
      padding-left: 80px;
    }

    .timeline-service {
      width: 80px;
    }

    .service-name {
      font-size: 0.6875rem;
    }

    .stats-bar {
      flex-direction: column;
      gap: 8px;
    }
  }
</style>
