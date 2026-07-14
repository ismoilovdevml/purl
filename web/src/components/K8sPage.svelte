<script>
  import { onMount, onDestroy } from 'svelte';
  import {
    podHealth,
    healthSummary,
    healthLoading,
    healthError,
    fetchPodHealth,
    startAutoRefresh,
    stopAutoRefresh,
  } from '../stores/k8sHealth.js';

  // Time range options
  const timeRanges = [
    { label: '1h', hours: 1 },
    { label: '6h', hours: 6 },
    { label: '24h', hours: 24 },
    { label: '7d', hours: 168 },
  ];

  let selectedHours = 1;
  let autoRefresh = true;
  let sortColumn = 'count';
  let sortDirection = 'desc';

  // Error type color mapping
  const ERROR_STYLES = {
    'CrashLoopBackOff': { color: '#f85149', bg: 'rgba(248, 81, 73, 0.15)', border: 'rgba(248, 81, 73, 0.4)' },
    'OOMKilled':        { color: '#f0883e', bg: 'rgba(240, 136, 62, 0.15)', border: 'rgba(240, 136, 62, 0.4)' },
    'ImagePullBackOff': { color: '#d29922', bg: 'rgba(210, 153, 34, 0.15)', border: 'rgba(210, 153, 34, 0.4)' },
    'ErrImagePull':     { color: '#d29922', bg: 'rgba(210, 153, 34, 0.15)', border: 'rgba(210, 153, 34, 0.4)' },
    'Evicted':          { color: '#f0883e', bg: 'rgba(240, 136, 62, 0.15)', border: 'rgba(240, 136, 62, 0.4)' },
    'NodeNotReady':     { color: '#f85149', bg: 'rgba(248, 81, 73, 0.15)', border: 'rgba(248, 81, 73, 0.4)' },
    'Pending':          { color: '#d29922', bg: 'rgba(210, 153, 34, 0.15)', border: 'rgba(210, 153, 34, 0.4)' },
    'CreateContainerError': { color: '#f85149', bg: 'rgba(248, 81, 73, 0.15)', border: 'rgba(248, 81, 73, 0.4)' },
    'RunContainerError': { color: '#f85149', bg: 'rgba(248, 81, 73, 0.15)', border: 'rgba(248, 81, 73, 0.4)' },
  };

  const DEFAULT_STYLE = { color: '#8b949e', bg: 'rgba(139, 148, 158, 0.15)', border: 'rgba(139, 148, 158, 0.4)' };

  function getErrorStyle(errorType) {
    return ERROR_STYLES[errorType] || DEFAULT_STYLE;
  }

  function formatTimestamp(ts) {
    if (!ts) return '-';
    try {
      const d = new Date(ts);
      return d.toLocaleString(undefined, {
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
      });
    } catch {
      return ts;
    }
  }

  function relativeTime(ts) {
    if (!ts) return '';
    try {
      const now = Date.now();
      const then = new Date(ts).getTime();
      const diffSec = Math.floor((now - then) / 1000);
      if (diffSec < 60) return `${diffSec}s ago`;
      if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`;
      if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`;
      return `${Math.floor(diffSec / 86400)}d ago`;
    } catch {
      return '';
    }
  }

  // Sorted pods
  $: sortedPods = (() => {
    const pods = [...($podHealth.pods || [])];
    pods.sort((a, b) => {
      let aVal = a[sortColumn];
      let bVal = b[sortColumn];

      // Numeric columns
      if (sortColumn === 'count') {
        aVal = Number(aVal) || 0;
        bVal = Number(bVal) || 0;
      } else if (sortColumn === 'first_seen' || sortColumn === 'last_seen') {
        aVal = aVal ? new Date(aVal).getTime() : 0;
        bVal = bVal ? new Date(bVal).getTime() : 0;
      } else {
        aVal = String(aVal || '').toLowerCase();
        bVal = String(bVal || '').toLowerCase();
      }

      if (aVal < bVal) return sortDirection === 'asc' ? -1 : 1;
      if (aVal > bVal) return sortDirection === 'asc' ? 1 : -1;
      return 0;
    });
    return pods;
  })();

  // Summary entries from store
  $: summaryEntries = Object.entries($healthSummary.summary || {});
  $: totalUnhealthy = $healthSummary.total_unhealthy || 0;

  // No-data signal from the backend: when there are zero K8s audit records the
  // health response reports has_data false/0. Distinguish this from a genuine
  // all-clear ("0 unhealthy") so we don't show a false green summary.
  // If the field is absent (older backend) we keep today's behavior.
  $: noK8sData = $healthSummary.has_data === false || $healthSummary.has_data === 0;

  function handleSort(column) {
    if (sortColumn === column) {
      sortDirection = sortDirection === 'asc' ? 'desc' : 'asc';
    } else {
      sortColumn = column;
      sortDirection = column === 'count' || column === 'last_seen' ? 'desc' : 'asc';
    }
  }

  function sortIndicator(column) {
    if (sortColumn !== column) return '';
    return sortDirection === 'asc' ? ' \u2191' : ' \u2193';
  }

  function handleTimeRange(hours) {
    selectedHours = hours;
    if (autoRefresh) {
      startAutoRefresh(30, selectedHours);
    } else {
      fetchPodHealth(selectedHours);
    }
  }

  function toggleAutoRefresh() {
    autoRefresh = !autoRefresh;
    if (autoRefresh) {
      startAutoRefresh(30, selectedHours);
    } else {
      stopAutoRefresh();
    }
  }

  function handlePodClick(pod) {
    // Dispatch a custom event for parent to handle log navigation
    const event = new CustomEvent('filter-logs', {
      bubbles: true,
      detail: {
        namespace: pod.namespace,
        pod_name: pod.pod_name,
        error_type: pod.error_type,
      },
    });
    document.dispatchEvent(event);
  }

  onMount(() => {
    if (autoRefresh) {
      startAutoRefresh(30, selectedHours);
    } else {
      fetchPodHealth(selectedHours);
    }
  });

  onDestroy(() => {
    stopAutoRefresh();
  });
</script>

<div class="k8s-page">
  <!-- Header -->
  <header class="page-header">
    <div class="header-left">
      <h1>K8s Pod Health</h1>
      {#if !$healthLoading && !$healthError && !noK8sData}
        <span class="pod-count-badge" class:healthy={totalUnhealthy === 0} class:unhealthy={totalUnhealthy > 0}>
          {totalUnhealthy} unhealthy
        </span>
      {/if}
    </div>
    <div class="header-right">
      <!-- Time range selector -->
      <div class="time-range">
        {#each timeRanges as range}
          <button
            class="range-btn"
            class:active={selectedHours === range.hours}
            on:click={() => handleTimeRange(range.hours)}
          >
            {range.label}
          </button>
        {/each}
      </div>

      <!-- Auto-refresh toggle -->
      <button class="auto-refresh-btn" class:active={autoRefresh} on:click={toggleAutoRefresh} title="Auto-refresh every 30s">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M23 4v6h-6M1 20v-6h6"/>
          <path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
        </svg>
        <span>{autoRefresh ? 'Auto' : 'Manual'}</span>
      </button>

      <!-- Manual refresh -->
      <button class="refresh-btn" on:click={() => fetchPodHealth(selectedHours)} disabled={$healthLoading} title="Refresh now">
        <svg class:spinning={$healthLoading} width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M23 4v6h-6M1 20v-6h6"/>
          <path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
        </svg>
      </button>
    </div>
  </header>

  <!-- Error state -->
  {#if $healthError}
    <div class="error-banner">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="12" cy="12" r="10"/>
        <line x1="12" y1="8" x2="12" y2="12"/>
        <line x1="12" y1="16" x2="12.01" y2="16"/>
      </svg>
      <span>{$healthError}</span>
      <button class="error-retry" on:click={() => fetchPodHealth(selectedHours)}>Retry</button>
    </div>

  <!-- Loading state (initial only) -->
  {:else if $healthLoading && $podHealth.pods.length === 0 && summaryEntries.length === 0}
    <div class="loading-state">
      <div class="spinner"></div>
      <span>Scanning pod health...</span>
    </div>

  <!-- No-data state: K8s audit ingestion has produced no records yet. -->
  {:else if noK8sData}
    <div class="empty-state">
      <div class="empty-icon neutral">
        <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="#8b949e" stroke-width="1.5">
          <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
        </svg>
      </div>
      <h3 class="neutral">No Kubernetes audit data yet</h3>
      <p>Purl has not received any K8s audit records. Enable K8s audit log ingestion for your cluster to see pod health here.</p>
    </div>

  {:else}
    <!-- Stats cards -->
    <div class="stats-row">
      <!-- Total unhealthy card -->
      <div class="stat-card total-card" class:has-issues={totalUnhealthy > 0}>
        <div class="stat-value" class:red={totalUnhealthy > 0} class:green={totalUnhealthy === 0}>
          {totalUnhealthy}
        </div>
        <div class="stat-label">Total Unhealthy</div>
      </div>

      <!-- Error type breakdown cards -->
      {#each summaryEntries as [errorType, count]}
        <div class="stat-card error-card" style="border-top: 3px solid {getErrorStyle(errorType).color}">
          <div class="stat-value" style="color: {getErrorStyle(errorType).color}">
            {typeof count === 'object' ? (count.pod_count || count.total_errors || 0) : count}
          </div>
          <div class="stat-label">{errorType}</div>
        </div>
      {/each}

      <!-- If no errors, show healthy card -->
      {#if summaryEntries.length === 0 && totalUnhealthy === 0}
        <div class="stat-card healthy-card">
          <div class="stat-value green">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#3fb950" stroke-width="2">
              <path d="M22 11.08V12a10 10 0 11-5.93-9.14"/>
              <polyline points="22 4 12 14.01 9 11.01"/>
            </svg>
          </div>
          <div class="stat-label">All Healthy</div>
        </div>
      {/if}
    </div>

    <!-- Pods table or empty state -->
    {#if sortedPods.length > 0}
      <div class="table-section">
        <div class="table-header">
          <h2>Unhealthy Pods <span class="count-badge">{$podHealth.total || sortedPods.length}</span></h2>
          {#if $healthLoading}
            <div class="inline-spinner"></div>
          {/if}
        </div>
        <div class="table-wrapper">
          <table class="pods-table">
            <thead>
              <tr>
                <th class="sortable" on:click={() => handleSort('namespace')}>
                  Namespace{sortIndicator('namespace')}
                </th>
                <th class="sortable" on:click={() => handleSort('pod_name')}>
                  Pod Name{sortIndicator('pod_name')}
                </th>
                <th class="sortable" on:click={() => handleSort('container')}>
                  Container{sortIndicator('container')}
                </th>
                <th class="sortable" on:click={() => handleSort('error_type')}>
                  Error Type{sortIndicator('error_type')}
                </th>
                <th class="sortable numeric" on:click={() => handleSort('count')}>
                  Count{sortIndicator('count')}
                </th>
                <th class="sortable" on:click={() => handleSort('first_seen')}>
                  First Seen{sortIndicator('first_seen')}
                </th>
                <th class="sortable" on:click={() => handleSort('last_seen')}>
                  Last Seen{sortIndicator('last_seen')}
                </th>
              </tr>
            </thead>
            <tbody>
              {#each sortedPods as pod}
                <tr class="pod-row" on:click={() => handlePodClick(pod)} title="Click to filter logs">
                  <td>
                    <span class="namespace-tag">{pod.namespace}</span>
                  </td>
                  <td class="pod-name-cell">
                    <span class="pod-name-text">{pod.pod_name}</span>
                  </td>
                  <td>
                    <span class="container-name">{pod.container || '-'}</span>
                  </td>
                  <td>
                    <span
                      class="error-badge"
                      style="color: {getErrorStyle(pod.error_type).color}; background: {getErrorStyle(pod.error_type).bg}; border-color: {getErrorStyle(pod.error_type).border}"
                    >
                      {pod.error_type}
                    </span>
                  </td>
                  <td class="count-cell">
                    {pod.count}
                  </td>
                  <td class="timestamp-cell" title={formatTimestamp(pod.first_seen)}>
                    {relativeTime(pod.first_seen)}
                  </td>
                  <td class="timestamp-cell" title={formatTimestamp(pod.last_seen)}>
                    {relativeTime(pod.last_seen)}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      </div>

    <!-- Empty state: all pods healthy -->
    {:else if !$healthLoading}
      <div class="empty-state">
        <div class="empty-icon">
          <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="#3fb950" stroke-width="1.5">
            <path d="M22 11.08V12a10 10 0 11-5.93-9.14"/>
            <polyline points="22 4 12 14.01 9 11.01"/>
          </svg>
        </div>
        <h3>All Pods Healthy</h3>
        <p>No unhealthy pods detected in the last {selectedHours >= 168 ? '7 days' : selectedHours >= 24 ? '24 hours' : selectedHours + ' hour' + (selectedHours !== 1 ? 's' : '')}</p>
      </div>
    {/if}
  {/if}
</div>

<style>
  .k8s-page {
    padding: 16px 20px;
    overflow-y: auto;
    height: calc(100vh - 60px);
  }

  /* Header */
  .page-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .header-left h1 {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .pod-count-badge {
    font-size: 0.75rem;
    font-weight: 600;
    padding: 3px 10px;
    border-radius: 12px;
  }

  .pod-count-badge.healthy {
    background: rgba(63, 185, 80, 0.15);
    color: #3fb950;
    border: 1px solid rgba(63, 185, 80, 0.3);
  }

  .pod-count-badge.unhealthy {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
    border: 1px solid rgba(248, 81, 73, 0.3);
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* Time range selector */
  .time-range {
    display: flex;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    overflow: hidden;
  }

  .range-btn {
    padding: 6px 12px;
    background: none;
    border: none;
    border-right: 1px solid #30363d;
    color: #8b949e;
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .range-btn:last-child {
    border-right: none;
  }

  .range-btn:hover {
    color: #c9d1d9;
    background: #21262d;
  }

  .range-btn.active {
    color: #58a6ff;
    background: rgba(88, 166, 255, 0.1);
  }

  /* Auto-refresh toggle */
  .auto-refresh-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #8b949e;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .auto-refresh-btn:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .auto-refresh-btn.active {
    color: #3fb950;
    border-color: rgba(63, 185, 80, 0.3);
  }

  /* Refresh button */
  .refresh-btn {
    padding: 6px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s;
  }

  .refresh-btn:hover {
    background: #30363d;
  }

  .refresh-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .refresh-btn svg.spinning {
    animation: spin 1s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* Error banner */
  .error-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 16px;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid rgba(248, 81, 73, 0.3);
    border-radius: 8px;
    color: #f85149;
    font-size: 0.8125rem;
  }

  .error-retry {
    margin-left: auto;
    padding: 4px 12px;
    background: rgba(248, 81, 73, 0.15);
    border: 1px solid rgba(248, 81, 73, 0.3);
    border-radius: 4px;
    color: #f85149;
    font-size: 0.75rem;
    cursor: pointer;
    transition: background 0.15s;
  }

  .error-retry:hover {
    background: rgba(248, 81, 73, 0.25);
  }

  /* Loading state */
  .loading-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    min-height: 300px;
    color: #8b949e;
    font-size: 0.875rem;
  }

  .spinner {
    width: 24px;
    height: 24px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .inline-spinner {
    width: 14px;
    height: 14px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  /* Stats cards row */
  .stats-row {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
    gap: 12px;
    margin-bottom: 16px;
  }

  .stat-card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 16px;
    transition: border-color 0.15s;
  }

  .total-card {
    border-left: 3px solid #58a6ff;
  }

  .total-card.has-issues {
    border-left-color: #f85149;
  }

  .healthy-card {
    border-left: 3px solid #3fb950;
  }

  .error-card {
    border-top-left-radius: 6px;
    border-top-right-radius: 6px;
  }

  .stat-value {
    font-size: 1.75rem;
    font-weight: 700;
    line-height: 1.2;
    color: #f0f6fc;
    display: flex;
    align-items: center;
  }

  .stat-value.red {
    color: #f85149;
  }

  .stat-value.green {
    color: #3fb950;
  }

  .stat-label {
    font-size: 0.6875rem;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.3px;
    margin-top: 4px;
  }

  /* Table section */
  .table-section {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
  }

  .table-header {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 16px;
    border-bottom: 1px solid #21262d;
  }

  .table-header h2 {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #c9d1d9;
    margin: 0;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .count-badge {
    background: #21262d;
    color: #8b949e;
    font-size: 0.6875rem;
    padding: 2px 8px;
    border-radius: 10px;
    font-weight: 500;
  }

  .table-wrapper {
    overflow-x: auto;
  }

  .pods-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.8125rem;
  }

  .pods-table th {
    text-align: left;
    padding: 10px 14px;
    font-size: 0.6875rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    border-bottom: 1px solid #21262d;
    background: #0d1117;
    white-space: nowrap;
    user-select: none;
  }

  .pods-table th.sortable {
    cursor: pointer;
    transition: color 0.15s;
  }

  .pods-table th.sortable:hover {
    color: #c9d1d9;
  }

  .pods-table th.numeric {
    text-align: right;
  }

  .pods-table td {
    padding: 10px 14px;
    border-bottom: 1px solid #21262d;
    color: #c9d1d9;
    vertical-align: middle;
  }

  .pod-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .pod-row:hover td {
    background: rgba(88, 166, 255, 0.04);
  }

  .pod-row:last-child td {
    border-bottom: none;
  }

  /* Namespace tag */
  .namespace-tag {
    display: inline-block;
    padding: 2px 8px;
    background: rgba(163, 113, 247, 0.1);
    border: 1px solid rgba(163, 113, 247, 0.25);
    border-radius: 4px;
    font-size: 0.6875rem;
    color: #a371f7;
    font-family: 'SFMono-Regular', Consolas, monospace;
  }

  /* Pod name */
  .pod-name-cell {
    max-width: 280px;
  }

  .pod-name-text {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 0.75rem;
    color: #58a6ff;
    word-break: break-all;
  }

  /* Container name */
  .container-name {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 0.75rem;
    color: #8b949e;
  }

  /* Error type badge */
  .error-badge {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 12px;
    font-size: 0.6875rem;
    font-weight: 600;
    border: 1px solid;
    white-space: nowrap;
  }

  /* Count cell */
  .count-cell {
    text-align: right;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: #f0f6fc;
  }

  /* Timestamp cell */
  .timestamp-cell {
    font-size: 0.75rem;
    color: #8b949e;
    white-space: nowrap;
  }

  /* Empty state */
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    padding: 60px 20px;
    text-align: center;
  }

  .empty-icon {
    width: 80px;
    height: 80px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(63, 185, 80, 0.08);
    border: 1px solid rgba(63, 185, 80, 0.2);
    border-radius: 50%;
  }

  .empty-state h3 {
    font-size: 1.125rem;
    font-weight: 600;
    color: #3fb950;
    margin: 8px 0 0 0;
  }

  /* Neutral (no-data) variant — distinct from the green all-clear */
  .empty-icon.neutral {
    background: rgba(139, 148, 158, 0.08);
    border-color: rgba(139, 148, 158, 0.2);
  }

  .empty-state h3.neutral {
    color: #c9d1d9;
  }

  .empty-state p {
    font-size: 0.875rem;
    color: #8b949e;
    margin: 0;
    max-width: 420px;
  }

  /* Responsive */
  @media (max-width: 1200px) {
    .stats-row {
      grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
    }
  }

  @media (max-width: 768px) {
    .page-header {
      flex-direction: column;
      align-items: flex-start;
      gap: 12px;
    }

    .header-right {
      width: 100%;
      flex-wrap: wrap;
    }

    .stats-row {
      grid-template-columns: repeat(2, 1fr);
    }

    .pods-table {
      font-size: 0.75rem;
    }

    .pods-table th,
    .pods-table td {
      padding: 8px 10px;
    }

    .pod-name-cell {
      max-width: 160px;
    }
  }
</style>
