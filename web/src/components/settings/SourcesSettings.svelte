<!--
  SourcesSettings Component
  Monitor log sources and ingestion pipelines

  Usage:
  <SourcesSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import Badge from '../ui/Badge.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import { formatCount, formatRelativeTime } from '../../utils/format.js';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import { box } from '../ui/icons.js';

  let sources = [];
  let loading = true;
  let error = '';
  let refreshing = false;

  onMount(() => {
    fetchSources();
  });

  async function fetchSources() {
    loading = sources.length === 0;
    refreshing = sources.length > 0;
    error = '';

    try {
      const data = await api.get('/sources');
      sources = data.sources || [];
    } catch (err) {
      // Keep the server's own wording when it sends one; anything else
      // (network failure, unparsable body) falls back to the generic message.
      error = err.body?.error || 'Failed to load sources';
      // A request that never reached the server stays silent, as before.
      if (!err.isNetworkError) toastError(error);
    } finally {
      loading = false;
      refreshing = false;
    }
  }

  function handleRefresh() {
    fetchSources();
    toastSuccess('Sources refreshed');
  }

  /**
   * Determine source status from last_event timestamp
   * active: event within last 5 minutes
   * stale: event within last 1 hour
   * inactive: no event for over 1 hour
   */
  function getStatus(lastEvent) {
    if (!lastEvent) return 'inactive';
    const now = new Date();
    const last = new Date(lastEvent);
    const diffMs = now - last;
    const diffMin = diffMs / 60000;

    if (diffMin < 5) return 'active';
    if (diffMin < 60) return 'stale';
    return 'inactive';
  }

  function statusLabel(status) {
    if (status === 'active') return 'Active';
    if (status === 'stale') return 'Stale';
    return 'Inactive';
  }

  function statusVariant(status) {
    if (status === 'active') return 'success';
    if (status === 'stale') return 'warning';
    return 'default';
  }

  function typeBadgeVariant(type) {
    switch (type) {
    case 'syslog':
      return 'info';
    case 'http':
      return 'primary';
    case 'otlp':
      return 'success';
    case 'filebeat':
      return 'warning';
    default:
      return 'default';
    }
  }

  // Computed stats
  $: totalSources = sources.length;
  $: activeSources = sources.filter(s => getStatus(s.last_event) === 'active').length;
  $: totalEvents = sources.reduce((sum, s) => sum + (s.events_count || 0), 0);
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Ingest Sources</h3>
    <p>Monitor log sources and ingestion pipelines</p>
  </div>

  <!-- Stats Overview -->
  <div class="stats-row">
    {#if loading}
      <div class="stat-card">
        <LoadingSpinner size="sm" label="Loading stats..." />
      </div>
    {:else}
      <div class="stat-card">
        <span class="stat-value">{totalSources}</span>
        <span class="stat-label">Total Sources</span>
      </div>
      <div class="stat-card" class:stat-success={activeSources > 0}>
        <span class="stat-value">{activeSources}</span>
        <span class="stat-label">Active Sources</span>
      </div>
      <div class="stat-card">
        <span class="stat-value">{formatCount(totalEvents)}</span>
        <span class="stat-label">Total Events</span>
      </div>
    {/if}
  </div>

  <!-- Sources List -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">
        Sources
        {#if !loading && sources.length > 0}
          <span class="source-count">({sources.length})</span>
        {/if}
      </span>
      <Button variant="ghost" size="sm" on:click={handleRefresh} loading={refreshing}>
        {refreshing ? 'Refreshing...' : 'Refresh'}
      </Button>
    </div>

    {#if error}
      <div class="error-box">{error}</div>
    {/if}

    {#if loading}
      <div class="empty-state">
        <LoadingSpinner size="sm" label="Loading sources..." />
      </div>
    {:else if sources.length === 0}
      <EmptyState icon={box} title="No sources detected">
        Sources appear automatically when logs are ingested via the API.
      </EmptyState>
    {:else}
      <div class="sources-list">
        {#each sources as source}
          {@const status = source.status || getStatus(source.last_event)}
          <div class="source-row">
            <div class="source-info">
              <div class="source-name-row">
                <span class="status-dot status-{status}" title={statusLabel(status)}></span>
                <span class="source-name">{source.name}</span>
                <Badge variant={typeBadgeVariant(source.type)} size="sm" pill>
                  {source.type || 'unknown'}
                </Badge>
              </div>
              <div class="source-meta">
                {#if source.first_seen}
                  <span class="meta-item">First seen {formatRelativeTime(source.first_seen)}</span>
                {/if}
              </div>
            </div>
            <div class="source-stats">
              <div class="source-stat">
                <span class="source-stat-value">{formatCount(source.events_count || 0)}</span>
                <span class="source-stat-label">events</span>
              </div>
              <div class="source-stat">
                <span class="source-stat-value">
                  {source.last_event ? formatRelativeTime(source.last_event) : 'Never'}
                </span>
                <span class="source-stat-label">last event</span>
              </div>
              <div class="source-stat source-status-badge">
                <Badge variant={statusVariant(status)} size="sm" dot>
                  {statusLabel(status)}
                </Badge>
              </div>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </Card>
</section>

<style>
  .settings-section {
    max-width: 900px;
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .section-header {
    margin-bottom: 0;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  /* Stats row */
  .stats-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  .stat-card {
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #21262d);
    border-radius: 8px;
    padding: 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 120px;
  }

  .stat-card.stat-success .stat-value {
    color: #3fb950;
  }

  .stat-value {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--text-primary, #f0f6fc);
    line-height: 1;
  }

  .stat-label {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  /* Group header */
  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .group-title {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary, #8b949e);
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .source-count {
    font-weight: 400;
    text-transform: none;
    letter-spacing: 0;
  }

  /* Error */
  .error-box {
    padding: 10px 16px;
    background: rgba(248, 81, 73, 0.1);
    color: #f85149;
    font-size: 0.8125rem;
    border-bottom: 1px solid rgba(248, 81, 73, 0.2);
  }

  /* Loading placeholder — the "no sources" case is <EmptyState>. */
  .empty-state {
    padding: 40px 16px;
    text-align: center;
    color: var(--text-secondary, #8b949e);
    font-size: 0.875rem;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
  }

  /* Sources list */
  .sources-list {
    display: flex;
    flex-direction: column;
  }

  .source-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
    transition: background 0.1s;
    gap: 16px;
  }

  .source-row:hover {
    background: var(--bg-tertiary, #161b22);
  }

  .source-row:last-child {
    border-bottom: none;
  }

  .source-info {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
    flex: 1;
  }

  .source-name-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .source-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary, #c9d1d9);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .source-meta {
    display: flex;
    align-items: center;
    gap: 12px;
    padding-left: 14px;
  }

  .meta-item {
    font-size: 0.75rem;
    color: var(--text-muted, #848d97);
  }

  /* Status dot */
  .status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot.status-active {
    background: #3fb950;
    box-shadow: 0 0 4px rgba(63, 185, 80, 0.4);
  }

  .status-dot.status-stale {
    background: #d29922;
    box-shadow: 0 0 4px rgba(210, 153, 34, 0.4);
  }

  .status-dot.status-inactive {
    background: var(--text-muted, #848d97);
  }

  /* Source stats */
  .source-stats {
    display: flex;
    align-items: center;
    gap: 24px;
    flex-shrink: 0;
  }

  .source-stat {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
  }

  .source-stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary, #c9d1d9);
    font-family: 'SF Mono', 'Fira Code', monospace;
    white-space: nowrap;
  }

  .source-stat-label {
    font-size: 0.6875rem;
    color: var(--text-muted, #848d97);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }

  .source-status-badge {
    min-width: 80px;
    align-items: flex-end;
  }
</style>
