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
  import { caretRight, check, chevronLeft, chevronRight, close, fileText } from '../ui/icons.js';
  import { api } from '../../utils/api.js';

  // Log list state
  let logs = [];
  let loading = true;
  let error = '';
  let searching = false;
  let totalCount = 0;

  // Stats state
  let stats = [];
  let loadingStats = true;

  // Filters
  let filterActor = '';
  let filterAction = '';
  let filterResourceType = '';
  let filterFrom = '';
  let filterTo = '';
  let dateError = '';

  // Pagination
  let limit = 50;
  let offset = 0;
  let hasMore = false;

  // Expand/collapse details
  let expandedRows = new Set();

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
    if (expandedRows.has(logId)) {
      expandedRows.delete(logId);
    } else {
      expandedRows.add(logId);
    }
    expandedRows = expandedRows; // trigger reactivity
  }

  function formatCount(num) {
    if (num == null) return '0';
    return num.toLocaleString('en-US');
  }

  function formatDate(dateStr) {
    if (!dateStr) return '—';
    try {
      const d = new Date(dateStr);
      const now = new Date();
      const diffMs = now - d;
      const diffMin = Math.floor(diffMs / 60000);
      const diffHr = Math.floor(diffMs / 3600000);

      if (diffMin < 1) return 'Just now';
      if (diffMin < 60) return `${diffMin}m ago`;
      if (diffHr < 24) return `${diffHr}h ago`;

      return d.toLocaleString('en-US', {
        month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit',
        hour12: false
      });
    } catch {
      return dateStr;
    }
  }

  function formatFullDate(dateStr) {
    if (!dateStr) return '';
    try {
      return new Date(dateStr).toLocaleString('en-US', {
        year: 'numeric', month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit', second: '2-digit',
        hour12: false
      });
    } catch {
      return dateStr;
    }
  }

  function actionColor(action) {
    if (!action) return '';
    if (action.startsWith('delete') || action === 'revoke') return 'action-danger';
    if (action.startsWith('create') || action === 'login') return 'action-success';
    if (action.startsWith('update') || action === 'change_password') return 'action-warning';
    return '';
  }

  function statusIcon(status) {
    return status === 'success' ? 'success' : 'failure';
  }

  // Compute total events from stats
  $: totalEvents24h = stats.reduce((sum, s) => sum + (s.count || 0), 0);
  $: uniqueActions = [...new Set(stats.map(s => s.action))];
  $: failureCount = stats.filter(s => s.status === 'failure').reduce((sum, s) => sum + (s.count || 0), 0);

  // Known actions for filter dropdown
  const knownActions = [
    'login', 'logout', 'login_failed',
    'create_user', 'update_user', 'delete_user', 'change_password',
    'create_alert', 'update_alert', 'delete_alert',
    'update_settings',
    'generate_api_key', 'revoke_api_key',
    'create_backup', 'restore_backup', 'delete_backup',
  ];

  const knownResourceTypes = [
    'user', 'alert', 'settings', 'api_key', 'backup', 'session',
  ];
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Audit Logs</h3>
    <p>Track security events and user activity</p>
  </div>

  <!-- 24h Stats Overview -->
  <div class="stats-row">
    {#if loadingStats}
      <Card padding="md">
        <LoadingSpinner size="sm" label="Loading stats..." />
      </Card>
    {:else}
      <div class="stat-card">
        <span class="stat-value">{totalEvents24h}</span>
        <span class="stat-label">Events (24h)</span>
      </div>
      <div class="stat-card">
        <span class="stat-value">{uniqueActions.length}</span>
        <span class="stat-label">Action Types</span>
      </div>
      <div class="stat-card" class:stat-danger={failureCount > 0}>
        <span class="stat-value">{failureCount}</span>
        <span class="stat-label">Failures (24h)</span>
      </div>

      {#if stats.length > 0}
        <div class="stat-card stat-breakdown">
          <span class="stat-label">Top Actions</span>
          <div class="breakdown-list">
            {#each stats.slice(0, 5) as entry}
              <div class="breakdown-item">
                <span class="breakdown-action {actionColor(entry.action)}">{entry.action}</span>
                <span class="breakdown-count">{entry.count}</span>
                <span class="breakdown-status status-{entry.status}">
                  <Icon
                    icon={entry.status === 'success' ? check : close}
                    size={12}
                    strokeWidth={3}
                    label={entry.status === 'success' ? 'Succeeded' : 'Failed'}
                  />
                </span>
              </div>
            {/each}
          </div>
        </div>
      {/if}
    {/if}
  </div>

  <!-- Filters -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">Filters</span>
      <div class="filter-actions">
        <Button variant="primary" size="sm" loading={searching} disabled={searching} on:click={applyFilters}>
          {searching ? 'Searching...' : 'Search'}
        </Button>
        <Button variant="ghost" size="sm" disabled={searching} on:click={clearFilters}>Clear</Button>
      </div>
    </div>
    <div class="filters-form">
      <div class="filter-row">
        <div class="filter-field">
          <label class="filter-label" for="audit-actor">Actor</label>
          <input
            id="audit-actor"
            type="text"
            class="filter-input"
            bind:value={filterActor}
            placeholder="Username..."
            on:keydown={(e) => e.key === 'Enter' && applyFilters()}
          />
        </div>
        <div class="filter-field">
          <label class="filter-label" for="audit-action">Action</label>
          <select id="audit-action" class="filter-select" bind:value={filterAction}>
            <option value="">All actions</option>
            {#each knownActions as action}
              <option value={action}>{action}</option>
            {/each}
          </select>
        </div>
        <div class="filter-field">
          <label class="filter-label" for="audit-resource">Resource Type</label>
          <select id="audit-resource" class="filter-select" bind:value={filterResourceType}>
            <option value="">All resources</option>
            {#each knownResourceTypes as rt}
              <option value={rt}>{rt}</option>
            {/each}
          </select>
        </div>
      </div>
      <div class="filter-row">
        <div class="filter-field">
          <label class="filter-label" for="audit-from">From</label>
          <input
            id="audit-from"
            type="datetime-local"
            class="filter-input"
            class:filter-input-error={dateError}
            bind:value={filterFrom}
          />
        </div>
        <div class="filter-field">
          <label class="filter-label" for="audit-to">To</label>
          <input
            id="audit-to"
            type="datetime-local"
            class="filter-input"
            class:filter-input-error={dateError}
            bind:value={filterTo}
          />
        </div>
      </div>
      {#if dateError}
        <div class="date-error">{dateError}</div>
      {/if}
    </div>
  </Card>

  <!-- Log Table -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">
        Events
        {#if !loading}
          <span class="event-count">
            Showing {formatCount(offset + 1)}&ndash;{formatCount(offset + logs.length)} of {formatCount(totalCount)}
          </span>
        {/if}
      </span>
      <Button variant="ghost" size="sm" on:click={() => { fetchLogs(); fetchStats(); }}>Refresh</Button>
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
      <div class="table-scroll-wrapper">
        <div class="log-table">
          <div class="table-header">
            <span class="col-time">Time (UTC)</span>
            <span class="col-actor">Actor</span>
            <span class="col-action">Action</span>
            <span class="col-resource">Resource</span>
            <span class="col-status">Status</span>
            <span class="col-ip">IP Address</span>
          </div>
          <div class="table-body">
            {#each logs as log}
              <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
              <div
                class="log-row"
                class:log-row-expandable={log.details}
                on:click={() => log.details && toggleDetails(log.id)}
                on:keydown={(e) => (e.key === 'Enter' || e.key === ' ') && log.details && toggleDetails(log.id)}
                role={log.details ? 'button' : undefined}
                tabindex={log.details ? 0 : undefined}
              >
                <span class="col-time" title={formatFullDate(log.timestamp) + ' (UTC)'}>
                  {formatDate(log.timestamp)}
                </span>
                <span class="col-actor">
                  <span class="actor-name">{log.actor || '—'}</span>
                </span>
                <span class="col-action">
                  <span class="action-badge {actionColor(log.action)}">
                    {log.action || '—'}
                  </span>
                </span>
                <span class="col-resource">
                  {#if log.resource_type}
                    <span class="resource-type">{log.resource_type}</span>
                    {#if log.resource_id}
                      <span class="resource-id">{log.resource_id}</span>
                    {/if}
                  {:else}
                    <span class="text-muted">—</span>
                  {/if}
                </span>
                <span class="col-status">
                  <span class="status-dot status-{statusIcon(log.status)}"></span>
                  {log.status || '—'}
                </span>
                <span class="col-ip">
                  <span class="ip-text">{log.ip_address || '—'}</span>
                  {#if log.details}
                    <Icon
                      icon={caretRight}
                      size={10}
                      class="expand-icon {expandedRows.has(log.id) ? 'expanded' : ''}"
                    />
                  {/if}
                </span>
              </div>
              {#if log.details && expandedRows.has(log.id)}
                <div class="log-details">
                  <span class="details-text">{log.details}</span>
                </div>
              {/if}
            {/each}
          </div>
        </div>
      </div>

      <!-- Pagination -->
      <div class="pagination">
        <Button variant="ghost" size="sm" disabled={offset === 0} on:click={prevPage}>
          <Icon icon={chevronLeft} size={12} strokeWidth={3} />
          Previous
        </Button>
        <span class="page-info">
          Showing {formatCount(offset + 1)}&ndash;{formatCount(offset + logs.length)} of {formatCount(totalCount)}
        </span>
        <Button variant="ghost" size="sm" disabled={!hasMore} on:click={nextPage}>
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

  /* Stats row */
  .stats-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  .stat-card {
    background: var(--bg-secondary);
    border: 1px solid var(--border-muted);
    border-radius: 8px;
    padding: 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 120px;
  }

  .stat-card.stat-danger .stat-value {
    color: #f85149;
  }

  .stat-card.stat-breakdown {
    flex: 1;
    min-width: 220px;
  }

  .stat-value {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--text-bright);
    line-height: 1;
  }

  .stat-label {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .breakdown-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-top: 8px;
  }

  .breakdown-item {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.75rem;
  }

  .breakdown-action {
    flex: 1;
    color: var(--text-secondary);
  }

  .breakdown-count {
    font-weight: 600;
    color: var(--text-primary);
    min-width: 28px;
    text-align: right;
  }

  .breakdown-status {
    display: inline-flex;
    align-items: center;
  }

  .status-success {
    color: #3fb950;
  }

  .status-failure {
    color: #f85149;
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

  /* Filters */
  .filters-form {
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .filter-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  .filter-field {
    display: flex;
    flex-direction: column;
    gap: 4px;
    flex: 1;
    min-width: 160px;
  }

  .filter-label {
    font-size: 0.7rem;
    font-weight: 500;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .filter-input,
  .filter-select {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-primary);
    padding: 6px 10px;
    font-size: 0.8125rem;
    transition: border-color 0.15s;
  }

  .filter-input:focus,
  .filter-select:focus {
    border-color: var(--color-primary);
    box-shadow: 0 0 0 2px rgba(88, 166, 255, 0.15);
  }

  .filter-select {
    cursor: pointer;
  }

  /* Date validation error */
  .date-error {
    font-size: 0.75rem;
    color: #f85149;
    padding: 2px 0 0;
  }

  .filter-input-error {
    border-color: #f85149 !important;
  }

  /* Error */
  .error-box {
    padding: 10px 16px;
    background: rgba(248, 81, 73, 0.1);
    color: #f85149;
    font-size: 0.8125rem;
    border-bottom: 1px solid rgba(248, 81, 73, 0.2);
  }

  /* Responsive table wrapper */
  .table-scroll-wrapper {
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }

  /* Table */
  .log-table {
    display: flex;
    flex-direction: column;
    min-width: 640px;
  }

  .table-header {
    display: grid;
    grid-template-columns: 100px 100px 140px 1fr 80px 120px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--border-color);
    font-size: 0.7rem;
    font-weight: 600;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .table-body {
    display: flex;
    flex-direction: column;
  }

  .log-row {
    display: grid;
    grid-template-columns: 100px 100px 140px 1fr 80px 120px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--border-muted);
    font-size: 0.8125rem;
    align-items: center;
    transition: background 0.1s;
  }

  .log-row:hover {
    background: var(--bg-secondary);
  }

  .log-row-expandable {
    cursor: pointer;
  }

  .log-row:last-child {
    border-bottom: none;
  }

  .col-time {
    color: var(--text-secondary);
    font-size: 0.75rem;
    cursor: default;
  }

  .actor-name {
    color: var(--text-primary);
    font-weight: 500;
  }

  .action-badge {
    display: inline-block;
    padding: 1px 6px;
    border-radius: 4px;
    font-size: 0.7rem;
    font-weight: 500;
    font-family: var(--font-mono);
    background: rgba(110, 118, 129, 0.15);
    color: var(--text-secondary);
  }

  .action-success {
    background: rgba(63, 185, 80, 0.15);
    color: #3fb950;
  }

  .action-danger {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
  }

  .action-warning {
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
  }

  .col-resource {
    display: flex;
    align-items: center;
    gap: 6px;
    overflow: hidden;
  }

  .resource-type {
    font-size: 0.7rem;
    font-weight: 500;
    padding: 1px 6px;
    border-radius: 4px;
    background: rgba(56, 139, 253, 0.1);
    color: #58a6ff;
    white-space: nowrap;
  }

  .resource-id {
    font-size: 0.75rem;
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-status {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot.status-success {
    background: #3fb950;
  }

  .status-dot.status-failure {
    background: #f85149;
  }

  .ip-text {
    font-size: 0.75rem;
    color: var(--text-muted);
    font-family: var(--font-mono);
  }

  .col-ip {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  /* :global() because the svg is rendered by <Icon>, outside this component's
     scoped-class rewriting. */
  .col-ip :global(.expand-icon) {
    color: var(--text-muted);
    transition: transform 0.15s ease;
    margin-left: auto;
  }

  .col-ip :global(.expand-icon.expanded) {
    transform: rotate(90deg);
  }

  .text-muted {
    color: var(--text-muted);
  }

  .log-details {
    padding: 4px 16px 8px 116px;
    border-bottom: 1px solid var(--border-muted);
  }

  .details-text {
    font-size: 0.75rem;
    color: var(--text-muted);
    font-style: italic;
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
