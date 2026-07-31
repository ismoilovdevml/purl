<!--
  TracesPage Component
  Trace exploration page with search, timeline visualization, and logs table.
  Supports searching by trace_id or request_id.

  API endpoints (shapes verified against lib/Purl/API/Controller/Traces.pm):
  - GET /api/traces/:trace_id
      { trace_id, total, hits: [{ id, timestamp, level, service, host, message,
                                  raw, meta, trace_id, request_id, span_id,
                                  parent_span_id }] }
  - GET /api/traces/:trace_id/timeline
      { trace_id, start_time, end_time,
        services: [{ service, start_time, end_time, log_count, error_count }] }
      NOTE: there are no per-operation spans. The server aggregates by service
      (GROUP BY service), so each service yields exactly ONE window. The bars
      below are derived from those windows, not from real span data.
  - GET /api/requests/:request_id
      { request_id, total, hits: [...same as above...] }

  The log rows arrive under `hits`, NOT `logs`, and the timeline is returned
  flat, NOT wrapped in a `timeline` key. Reading `logs`/`timeline` is what made
  a populated trace render as "No logs found" with no timeline at all.
-->
<script>
  import { onMount } from 'svelte';
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import LoadingSpinner from './ui/LoadingSpinner.svelte';
  import Badge from './ui/Badge.svelte';
  import Icon from './ui/Icon.svelte';
  import EmptyState from './ui/EmptyState.svelte';
  import { search, alertTriangle, alertCircle, activity } from './ui/icons.js';
  import { success as toastSuccess, error as toastError } from '../stores/toast.js';
  import { formatTimestamp, formatFullTimestamp } from '../utils/format.js';
  import { api } from '../utils/api.js';

  // Service colors for timeline visualization
  const SERVICE_COLORS = [
    '#58a6ff', '#3fb950', '#d29922', '#f78166', '#a371f7',
    '#79c0ff', '#7ee787', '#e3b341', '#ffa657', '#d2a8ff',
    '#56d4dd', '#f0883e', '#bc8cff', '#39d353', '#db6d28',
  ];

  let recentTraces = [];
  let recentLoading = false;
  let recentRange = '24h';
  let recentError = '';

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

  /**
   * This page has its own wording for a missing trace ("Trace not found (404)")
   * which reads better than ApiError's generic "Request failed (HTTP 404)".
   * Keep the server's own message when it sent one.
   */
  function traceLookupError(err, label) {
    const fromServer = err?.body?.error;
    if (fromServer) return new Error(fromServer);
    return new Error(err?.status ? `${label} (${err.status})` : (err?.message || label));
  }

  /**
   * Turn the timeline endpoint's flat per-service windows into bars.
   *
   * The server aggregates GROUP BY service, so each entry is one service's
   * first..last log window as an ISO-8601 string (ClickHouse DateTime64(3), so
   * milliseconds survive). Offsets are measured from the earliest service start
   * — the endpoint's own `start_time` is the same value, but deriving it here
   * keeps the bars consistent even if a future server omits it.
   *
   * Returns null when there is nothing renderable, so the markup can simply
   * test `timelineRows.length`.
   */
  function buildTimeline(data) {
    const services = Array.isArray(data?.services) ? data.services : [];
    if (services.length === 0) return null;

    const windows = services
      .map(s => ({
        service: s.service || 'unknown',
        startMs: Date.parse(s.start_time),
        endMs: Date.parse(s.end_time),
        logCount: s.log_count ?? 0,
        errorCount: s.error_count ?? 0,
      }))
      .filter(w => Number.isFinite(w.startMs) && Number.isFinite(w.endMs));

    if (windows.length === 0) return null;

    const traceStart = Math.min(...windows.map(w => w.startMs));
    const traceEnd = Math.max(...windows.map(w => w.endMs));

    return {
      durationMs: Math.max(traceEnd - traceStart, 0),
      spans: windows.map(w => ({
        service: w.service,
        startMs: w.startMs - traceStart,
        // A service that logged once has start == end. Clamp at 0 so the
        // width math below can still give it a visible minimum-width bar.
        durationMs: Math.max(w.endMs - w.startMs, 0),
        logCount: w.logCount,
        errorCount: w.errorCount,
      })),
    };
  }

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

  function selectTrace(traceId) {
    searchQuery = traceId;
    handleSearch();
  }

  function changeRange(range) {
    recentRange = range;
    fetchRecentTraces();
  }

  onMount(() => {
    fetchRecentTraces();
  });

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
        let data;
        try {
          data = await api.get(`/requests/${encodeURIComponent(query)}`);
        } catch (err) {
          throw traceLookupError(err, 'Request not found');
        }
        logs = data.hits || [];
        requestId = data.request_id || query;
        total = data.total || logs.length;
        searchType = 'request';
      } else {
        // Fetch trace logs and timeline in parallel. allSettled, not all:
        // a missing timeline must not sink the logs we did get.
        const [logsResult, timelineResult] = await Promise.allSettled([
          api.get(`/traces/${encodeURIComponent(query)}`),
          api.get(`/traces/${encodeURIComponent(query)}/timeline`),
        ]);

        if (logsResult.status === 'rejected') {
          throw traceLookupError(logsResult.reason, 'Trace not found');
        }

        const logsData = logsResult.value;
        logs = logsData.hits || [];
        traceId = logsData.trace_id || query;
        total = logsData.total || logs.length;
        searchType = 'trace';

        if (timelineResult.status === 'fulfilled') {
          timeline = buildTimeline(timelineResult.value);
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
  $: totalDuration = timeline?.durationMs || 0;
  $: levelCounts = logs.reduce((acc, l) => {
    const level = (l.level || 'unknown').toLowerCase();
    acc[level] = (acc[level] || 0) + 1;
    return acc;
  }, {});
  $: hasErrors = (levelCounts['error'] || 0) + (levelCounts['fatal'] || 0) + (levelCounts['critical'] || 0) > 0;

  /**
   * One row per service, each holding the single bar the API gives us.
   *
   * A whole-trace duration of 0 (every service logged inside the same
   * millisecond) is a real case, not an error: the bars then span the full
   * track rather than the section disappearing.
   */
  $: timelineRows = (() => {
    if (!timeline?.spans?.length) return [];
    const dur = timeline.durationMs;
    return timeline.spans.map(span => ({
      service: span.service,
      color: getServiceColor(span.service),
      logCount: span.logCount,
      errorCount: span.errorCount,
      durationMs: span.durationMs,
      startMs: span.startMs,
      leftPct: dur > 0 ? (span.startMs / dur) * 100 : 0,
      widthPct: dur > 0 ? Math.max((span.durationMs / dur) * 100, 0.5) : 100,
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
          <Icon slot="icon" icon={search} size={16} />
        </Input>
      </div>
      <Button variant="primary" on:click={handleSearch} loading={loading}>
        <Icon icon={search} size={16} />
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
      <div class="empty-wrap">
        <EmptyState icon={alertTriangle} title={errorMsg}>
          Check the ID and try again.
        </EmptyState>
      </div>
    {:else if !hasSearched}
      <!-- Recent Traces -->
      <div class="recent-section">
        <div class="recent-header">
          <h2>Recent Traces</h2>
          <div class="range-buttons">
            {#each [['1h', '1h'], ['24h', '24h'], ['7d', '7d']] as [label, value]}
              <button
                class="range-btn"
                class:active={recentRange === value}
                on:click={() => changeRange(value)}
              >{label}</button>
            {/each}
          </div>
        </div>

        {#if recentLoading}
          <div class="loading-container" style="min-height: 200px;">
            <LoadingSpinner size="md" label="Loading recent traces..." centered />
          </div>
        {:else if recentError}
          <div class="empty-wrap">
            <EmptyState icon={alertCircle} title={recentError} tone="error">
              <svelte:fragment slot="actions">
                <button class="retry-btn" on:click={fetchRecentTraces}>Retry</button>
              </svelte:fragment>
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
                  <tr class="trace-row" class:has-errors={trace.error_count > 0} on:click={() => selectTrace(trace.trace_id)}>
                    <td class="col-trace-id">
                      <span class="trace-id-text">{trace.trace_id}</span>
                    </td>
                    <td class="col-services">
                      {#each (trace.services || []).slice(0, 3) as svc}
                        <span class="service-chip" style="border-color: {getServiceColor(svc)}; color: {getServiceColor(svc)}">{svc}</span>
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

                  <div
                    class="timeline-span"
                    style="left: {row.leftPct}%; width: {row.widthPct}%; background: {row.color};"
                    title="{row.service}: {formatDuration(row.durationMs)} ({formatDuration(row.startMs)} - {formatDuration(row.startMs + row.durationMs)}), {row.logCount} log{row.logCount !== 1 ? 's' : ''}{row.errorCount > 0 ? `, ${row.errorCount} error${row.errorCount !== 1 ? 's' : ''}` : ''}"
                  >
                    {#if row.widthPct > 8}
                      <span class="span-label">{row.logCount} log{row.logCount !== 1 ? 's' : ''}</span>
                    {/if}
                  </div>
                </div>
              </div>
            {/each}
          </div>
        </div>
      {/if}

      <!-- Logs Table -->
      {#if logs.length === 0 && hasSearched && !loading}
        <div class="empty-wrap short">
          <EmptyState title="No logs in this trace">
            The trace was found but contains no log entries.
          </EmptyState>
        </div>
      {:else if logs.length > 0}
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
    color: #848d97;
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

  /* Keeps the content area from collapsing when an EmptyState replaces
     a full table — the same reserved height the old block had. */
  .empty-wrap {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 300px;
  }

  .empty-wrap.short {
    min-height: 150px;
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
    color: #848d97;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .stat-value.mono {
    font-family: var(--font-mono);
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
    color: #848d97;
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
    color: #848d97;
    font-family: var(--font-mono);
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
    font-family: var(--font-mono);
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
    color: #848d97;
  }

  .message-text {
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--font-mono);
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
    font-family: var(--font-mono);
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

  /* Recent Traces */
  .recent-section {
    flex: 1;
  }

  .recent-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
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
