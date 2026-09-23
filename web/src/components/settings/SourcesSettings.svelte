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
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import StatTile from '../ui/StatTile.svelte';
  import SourceRow from './sources/SourceRow.svelte';
  import { formatCount } from '../../utils/format.js';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import { box } from '../ui/icons.js';

  let sources = $state([]);
  let loading = $state(true);
  let error = $state('');
  let refreshing = $state(false);

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
      error = err.userMessage || 'Failed to load sources';
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

  // Computed stats
  const totalSources = $derived(sources.length);
  const activeSources = $derived(sources.filter(s => getStatus(s.last_event) === 'active').length);
  const totalEvents = $derived(sources.reduce((sum, s) => sum + (s.events_count || 0), 0));
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Ingest Sources</h3>
    <p>Monitor log sources and ingestion pipelines</p>
  </div>

  <!-- Stats Overview -->
  <div class="stats-row">
    {#if loading}
      <StatTile>
        <LoadingSpinner size="sm" label="Loading stats..." />
      </StatTile>
    {:else}
      <StatTile value={totalSources} label="Total Sources" />
      <StatTile value={activeSources} label="Active Sources" tone={activeSources > 0 ? 'success' : null} />
      <StatTile value={formatCount(totalEvents)} label="Total Events" />
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
      <Button variant="ghost" size="sm" onclick={handleRefresh} loading={refreshing}>
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
          <SourceRow {source} {status} />
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
    color: var(--text-bright);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin: 0;
  }

  /* Stats row */
  .stats-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  /* Group header */
  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-muted);
  }

  .group-title {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary);
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
    color: var(--text-secondary);
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
</style>
