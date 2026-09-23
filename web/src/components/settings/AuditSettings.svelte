<!--
  AuditSettings Component
  View and filter audit log events with statistics

  Usage:
  <AuditSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import Icon from '../ui/Icon.svelte';
  import { chevronLeft, chevronRight, fileText } from '../ui/icons.js';
  import { api } from '../../utils/api.js';
  import { formatNumber } from '../../utils/format.js';
  import AuditStats from './audit/AuditStats.svelte';
  import AuditFilterForm from './audit/AuditFilterForm.svelte';
  import AuditLogTable from './audit/AuditLogTable.svelte';

  // Log list state
  let logs = $state([]);
  let loading = $state(true);
  let error = $state('');
  let searching = $state(false);
  let totalCount = $state(0);

  // Stats state
  let stats = $state([]);
  let loadingStats = $state(true);

  // Filters
  let filterActor = $state('');
  let filterAction = $state('');
  let filterResourceType = $state('');
  let filterFrom = $state('');
  let filterTo = $state('');
  let dateError = $state('');

  // Pagination
  const limit = 50;
  let offset = $state(0);
  let hasMore = $state(false);

  // Expand/collapse details
  let expandedRows = $state(new Set());

  onMount(() => {
    fetchStats();
    fetchLogs();
  });

  async function fetchStats() {
    loadingStats = true;
    try {
      const data = await api.get('/audit/stats');
      stats = data.stats || [];
    } catch {
      // stats are optional, don't block
    }
    loadingStats = false;
  }

  async function fetchLogs() {
    loading = true;
    searching = true;
    error = '';
    try {
      // api.js drops null/'' entries, so optional filters can be passed inline.
      const data = await api.get('/audit', {
        query: {
          limit: limit + 1, // fetch 1 extra to detect "has more"
          offset,
          actor: filterActor.trim() || null,
          action: filterAction || null,
          resource_type: filterResourceType || null,
          from: filterFrom ? Math.floor(new Date(filterFrom).getTime() / 1000) : null,
          to: filterTo ? Math.floor(new Date(filterTo).getTime() / 1000) : null,
        },
      });
      const fetched = data.logs || [];
      hasMore = fetched.length > limit;
      logs = fetched.slice(0, limit);
      totalCount = data.total_count ?? fetched.length;
    } catch (err) {
      // Same wording as before: the server's own message when it sends one,
      // otherwise the generic line (also used for network failures).
      error = err?.body?.error || 'Failed to load audit logs';
    }
    loading = false;
    searching = false;
  }

  function applyFilters() {
    dateError = '';
    if (filterFrom && filterTo) {
      const from = new Date(filterFrom);
      const to = new Date(filterTo);
      if (from >= to) {
        dateError = '"From" date must be before "To" date';
        return;
      }
    }
    offset = 0;
    expandedRows = new Set();
    fetchLogs();
  }

  function clearFilters() {
    filterActor = '';
    filterAction = '';
    filterResourceType = '';
    filterFrom = '';
    filterTo = '';
    dateError = '';
    offset = 0;
    expandedRows = new Set();
    fetchLogs();
  }

  function nextPage() {
    offset += limit;
    expandedRows = new Set();
    fetchLogs();
  }

  function prevPage() {
    offset = Math.max(0, offset - limit);
    expandedRows = new Set();
    fetchLogs();
  }

  function toggleDetails(logId) {
    // A fresh Set: $state does not track Set mutations, and reassigning the
    // same reference is a no-op in runes mode.
    // eslint-disable-next-line svelte/prefer-svelte-reactivity
    const next = new Set(expandedRows);
    if (next.has(logId)) {
      next.delete(logId);
    } else {
      next.add(logId);
    }
    expandedRows = next;
  }

  // "Showing 1–50 of 1,234" — full numbers with separators, not compact
  // counts: this is a pagination position.
  const rangeLabel = $derived(
    `Showing ${formatNumber(offset + 1)}\u2013${formatNumber(offset + logs.length)} of ${formatNumber(totalCount)}`
  );
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Audit Logs</h3>
    <p>Track security events and user activity</p>
  </div>

  <AuditStats {stats} loading={loadingStats} />

  <!-- Filters -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">Filters</span>
      <div class="filter-actions">
        <Button variant="primary" size="sm" loading={searching} disabled={searching} onclick={applyFilters}>
          {searching ? 'Searching...' : 'Search'}
        </Button>
        <Button variant="ghost" size="sm" disabled={searching} onclick={clearFilters}>Clear</Button>
      </div>
    </div>
    <AuditFilterForm
      bind:actor={filterActor}
      bind:action={filterAction}
      bind:resourceType={filterResourceType}
      bind:from={filterFrom}
      bind:to={filterTo}
      {dateError}
      onsubmit={applyFilters}
    />
  </Card>

  <!-- Log Table -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">
        Events
        {#if !loading}
          <span class="event-count">
            {rangeLabel}
          </span>
        {/if}
      </span>
      <Button variant="ghost" size="sm" onclick={() => { fetchLogs(); fetchStats(); }}>Refresh</Button>
    </div>

    {#if error}
      <div class="error-box">{error}</div>
    {/if}

    {#if loading}
      <div class="empty-state">
        <LoadingSpinner size="sm" label="Loading audit logs..." />
      </div>
    {:else if logs.length === 0}
      <EmptyState icon={fileText} title="No audit events found." size="sm" />
    {:else}
      <AuditLogTable {logs} {expandedRows} ontoggle={toggleDetails} />

      <!-- Pagination -->
      <div class="pagination">
        <Button variant="ghost" size="sm" disabled={offset === 0} onclick={prevPage}>
          <Icon icon={chevronLeft} size={12} strokeWidth={3} />
          Previous
        </Button>
        <span class="page-info">
          {rangeLabel}
        </span>
        <Button variant="ghost" size="sm" disabled={!hasMore} onclick={nextPage}>
          Next
          <Icon icon={chevronRight} size={12} strokeWidth={3} />
        </Button>
      </div>
    {/if}
  </Card>
</section>

<style>
  .settings-section {
    max-width: 1000px;
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

  .event-count {
    font-weight: 400;
    text-transform: none;
    letter-spacing: 0;
  }

  .filter-actions {
    display: flex;
    gap: 6px;
  }

  /* Error */
  .error-box {
    padding: 10px 16px;
    background: rgba(248, 81, 73, 0.1);
    color: #f85149;
    font-size: 0.8125rem;
    border-bottom: 1px solid rgba(248, 81, 73, 0.2);
  }

  /* Pagination */
  .pagination {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 16px;
    padding: 12px 16px;
    border-top: 1px solid var(--border-muted);
  }

  .page-info {
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  .empty-state {
    padding: 32px 16px;
    text-align: center;
    color: var(--text-secondary);
    font-size: 0.875rem;
  }
</style>
