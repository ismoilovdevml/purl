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
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import LoadingSpinner from './ui/LoadingSpinner.svelte';
  import Badge from './ui/Badge.svelte';
  import Icon from './ui/Icon.svelte';
  import EmptyState from './ui/EmptyState.svelte';
  import RecentTraces from './traces/RecentTraces.svelte';
  import TraceStats from './traces/TraceStats.svelte';
  import TraceTimeline from './traces/TraceTimeline.svelte';
  import TraceLogsTable from './traces/TraceLogsTable.svelte';
  import { search, alertTriangle } from './ui/icons.js';
  import { success as toastSuccess, error as toastError } from '../stores/toast.js';
  import { createServiceColorer } from '../utils/colors.js';
  import { api } from '../utils/api.js';

  let searchQuery = $state('');
  let searchType = $state('trace'); // 'trace' or 'request'
  let loading = $state(false);
  // Raw: result sets are replaced wholesale, never mutated in place.
  let logs = $state.raw([]);
  let timeline = $state.raw(null);
  let traceId = $state('');
  let requestId = $state('');
  let total = $state(0);
  let errorMsg = $state('');
  let hasSearched = $state(false);

  // Service -> colour, shared by the recent list, the timeline and the logs
  // table so one service keeps one colour everywhere. A fresh picker per
  // lookup restarts the palette, as before.
  let serviceColor = $state.raw(createServiceColorer());

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
   * test `timeline?.spans?.length`.
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

  function selectTrace(id) {
    searchQuery = id;
    handleSearch();
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
    serviceColor = createServiceColorer();

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
    if (event?.key === 'Enter') {
      handleSearch();
    }
  }

  // Compute stats from logs
  const uniqueServices = $derived([...new Set(logs.map(l => l.service).filter(Boolean))]);
  const totalDuration = $derived(timeline?.durationMs || 0);
  const levelCounts = $derived(logs.reduce((acc, l) => {
    const level = (l.level || 'unknown').toLowerCase();
    acc[level] = (acc[level] || 0) + 1;
    return acc;
  }, {}));
  const hasErrors = $derived((levelCounts['error'] || 0) + (levelCounts['fatal'] || 0) + (levelCounts['critical'] || 0) > 0);

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
          onkeydown={handleKeydown}
        >
          {#snippet icon()}
            <Icon icon={search} size={16} />
          {/snippet}
        </Input>
      </div>
      <Button variant="primary" onclick={handleSearch} loading={loading}>
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
      <RecentTraces {serviceColor} onselect={selectTrace} />
    {:else}
      <TraceStats
        id={traceId || requestId}
        {searchType}
        {total}
        serviceCount={uniqueServices.length}
        durationMs={totalDuration}
        {levelCounts}
      />

      {#if timeline?.spans?.length}
        <TraceTimeline {timeline} {serviceColor} />
      {/if}

      {#if logs.length === 0 && hasSearched && !loading}
        <div class="empty-wrap short">
          <EmptyState title="No logs in this trace">
            The trace was found but contains no log entries.
          </EmptyState>
        </div>
      {:else if logs.length > 0}
        <TraceLogsTable {logs} {serviceColor} />
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

  @media (max-width: 640px) {
    .traces-page {
      padding: 12px 14px;
    }

    .search-bar {
      flex-direction: column;
    }
  }
</style>
