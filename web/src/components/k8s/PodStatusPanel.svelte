<!--
  PodStatusPanel - K8s Pod Health Visualization
  Shows unhealthy pods detected from log patterns
  with color-coded badges and auto-refresh.
-->
<script>
  import { onMount, onDestroy } from 'svelte';
  import Badge from '../ui/Badge.svelte';
  import Card from '../ui/Card.svelte';
  import Icon from '../ui/Icon.svelte';
  import { refresh, alertCircle, activity, checkCircle } from '../ui/icons.js';
  import {
    podHealth,
    healthSummary,
    healthLoading,
    healthError,
    startAutoRefresh,
    stopAutoRefresh,
    fetchPodHealth,
  } from '../../stores/k8sHealth.js';

  /** Lookback window in hours */
  export let hours = 1;

  /** Auto-refresh interval in seconds (0 to disable) */
  export let refreshInterval = 30;

  // Error type to color mapping
  const ERROR_COLORS = {
    'CrashLoopBackOff': { color: '#ef4444', bg: 'rgba(239, 68, 68, 0.15)', variant: 'error' },
    'OOMKilled':        { color: '#ef4444', bg: 'rgba(239, 68, 68, 0.15)', variant: 'error' },
    'ImagePullBackOff': { color: '#f97316', bg: 'rgba(249, 115, 22, 0.15)', variant: 'warning' },
    'Evicted':          { color: '#f97316', bg: 'rgba(249, 115, 22, 0.15)', variant: 'warning' },
    'NodeNotReady':     { color: '#ef4444', bg: 'rgba(239, 68, 68, 0.15)', variant: 'error' },
    'Running':          { color: '#4ade80', bg: 'rgba(74, 222, 128, 0.15)', variant: 'success' },
    'Pending':          { color: '#eab308', bg: 'rgba(234, 179, 8, 0.15)', variant: 'warning' },
  };

  function getErrorStyle(errorType) {
    return ERROR_COLORS[errorType] || ERROR_COLORS['CrashLoopBackOff'];
  }

  function getBadgeVariant(errorType) {
    const info = ERROR_COLORS[errorType];
    return info ? info.variant : 'error';
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

  // No-data signal: backend reports has_data false/0 when no K8s audit records
  // exist. Distinct from a genuine all-clear so we don't show "All Pods Healthy".
  // Absent field (older backend) keeps today's behavior.
  $: noK8sData = $healthSummary.has_data === false || $healthSummary.has_data === 0;

  // Summary cards derived from store
  let summaryCards = [];
  $: {
    const s = $healthSummary.summary || {};
    summaryCards = Object.entries(s).map(([type, data]) => ({
      type,
      podCount: data.pod_count || 0,
      totalErrors: data.total_errors || 0,
      style: getErrorStyle(type),
    }));
  }

  onMount(() => {
    if (refreshInterval > 0) {
      startAutoRefresh(refreshInterval, hours);
    } else {
      fetchPodHealth(hours);
    }
  });

  onDestroy(() => {
    stopAutoRefresh();
  });
</script>

<div class="pod-status-panel">
  <Card title="Pod Health" subtitle="Log-based detection of unhealthy K8s pods">
    <svelte:fragment slot="actions">
      <button
        class="refresh-btn"
        on:click={() => fetchPodHealth(hours)}
        disabled={$healthLoading}
        aria-label="Refresh pod health"
      >
        {#if $healthLoading}
          <span class="spinner"></span>
        {:else}
          <Icon icon={refresh} size={14} />
        {/if}
      </button>
    </svelte:fragment>

    {#if $healthError}
      <div class="health-error">
        <Icon icon={alertCircle} size={16} />
        <span>{$healthError}</span>
      </div>
    {:else if noK8sData && !$healthLoading}
      <div class="empty-state no-data">
        <Icon icon={activity} size={32} strokeWidth={1.5} color="#8b949e" />
        <p class="no-data-title">No Kubernetes audit data yet</p>
        <p>Enable K8s audit log ingestion for your cluster to see pod health here.</p>
      </div>
    {:else}
      <!-- Summary cards -->
      <div class="summary-grid">
        <div class="summary-card total">
          <div class="summary-value">{$healthSummary.total_unhealthy || 0}</div>
          <div class="summary-label">Unhealthy Pods</div>
        </div>
        {#each summaryCards as card}
          <div class="summary-card" style="border-left: 3px solid {card.style.color}">
            <div class="summary-value" style="color: {card.style.color}">{card.podCount}</div>
            <div class="summary-label">{card.type}</div>
            <div class="summary-errors">{card.totalErrors} errors</div>
          </div>
        {/each}
        {#if summaryCards.length === 0 && !$healthLoading}
          <div class="summary-card healthy">
            <div class="summary-value" style="color: #4ade80">0</div>
            <div class="summary-label">All Pods Healthy</div>
          </div>
        {/if}
      </div>

      <!-- Pods table -->
      {#if $podHealth.pods && $podHealth.pods.length > 0}
        <div class="table-wrapper">
          <table class="pods-table">
            <thead>
              <tr>
                <th>Pod</th>
                <th>Namespace</th>
                <th>Status</th>
                <th>Errors</th>
                <th>Last Seen</th>
              </tr>
            </thead>
            <tbody>
              {#each $podHealth.pods as pod}
                <tr>
                  <td class="pod-name">
                    <span class="name-text">{pod.name}</span>
                    {#if pod.container}
                      <span class="container-text">{pod.container}</span>
                    {/if}
                  </td>
                  <td>
                    <span class="namespace-tag">{pod.namespace}</span>
                  </td>
                  <td>
                    <Badge variant={getBadgeVariant(pod.error_type)} size="sm" pill>
                      {pod.error_type}
                    </Badge>
                  </td>
                  <td class="error-count">{pod.count}</td>
                  <td class="timestamp">{formatTimestamp(pod.last_seen)}</td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {:else if !$healthLoading}
        <div class="empty-state">
          <Icon icon={checkCircle} size={32} strokeWidth={1.5} color="#4ade80" />
          <p>No unhealthy pods detected in the last {hours} hour{hours !== 1 ? 's' : ''}</p>
        </div>
      {/if}

      {#if $healthLoading && (!$podHealth.pods || $podHealth.pods.length === 0)}
        <div class="loading-state">
          <span class="spinner"></span>
          <span>Scanning pod health...</span>
        </div>
      {/if}
    {/if}
  </Card>
</div>

<style>
  .pod-status-panel {
    width: 100%;
  }

  .refresh-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-secondary);
    cursor: pointer;
    transition: all 0.15s;
  }

  .refresh-btn:hover {
    background: var(--border-color);
    color: var(--text-primary);
  }

  .refresh-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  /* Health error */
  .health-error {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid rgba(248, 81, 73, 0.3);
    border-radius: 6px;
    color: #f85149;
    font-size: 13px;
  }

  /* Summary grid */
  .summary-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
    gap: 12px;
    margin-bottom: 16px;
  }

  .summary-card {
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 8px;
    padding: 12px;
  }

  .summary-card.total {
    border-left: 3px solid #58a6ff;
  }

  .summary-card.healthy {
    border-left: 3px solid #4ade80;
  }

  .summary-value {
    font-size: 24px;
    font-weight: 700;
    line-height: 1.2;
    color: var(--text-primary);
  }

  .summary-label {
    font-size: 12px;
    color: var(--text-secondary);
    margin-top: 2px;
  }

  .summary-errors {
    font-size: 11px;
    color: var(--text-secondary);
    margin-top: 4px;
    opacity: 0.7;
  }

  /* Pods table */
  .table-wrapper {
    overflow-x: auto;
  }

  .pods-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }

  .pods-table th {
    text-align: left;
    padding: 8px 12px;
    font-size: 11px;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    border-bottom: 1px solid var(--border-color);
    background: var(--bg-tertiary);
  }

  .pods-table td {
    padding: 8px 12px;
    border-bottom: 1px solid var(--border-color);
    color: var(--text-primary);
    vertical-align: middle;
  }

  .pods-table tr:hover td {
    background: rgba(88, 166, 255, 0.04);
  }

  .pod-name {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .name-text {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
    color: #58a6ff;
  }

  .container-text {
    font-size: 11px;
    color: var(--text-secondary);
  }

  .namespace-tag {
    display: inline-block;
    padding: 2px 8px;
    background: rgba(163, 113, 247, 0.1);
    border: 1px solid rgba(163, 113, 247, 0.25);
    border-radius: 4px;
    font-size: 11px;
    color: #a371f7;
    font-family: 'SFMono-Regular', Consolas, monospace;
  }

  .error-count {
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }

  .timestamp {
    font-size: 12px;
    color: var(--text-secondary);
    white-space: nowrap;
  }

  /* Empty state */
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 32px 16px;
    text-align: center;
  }

  .empty-state p {
    font-size: 13px;
    color: var(--text-secondary);
  }

  .empty-state .no-data-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
    margin: 0;
  }

  /* Loading state */
  .loading-state {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 24px;
    font-size: 13px;
    color: var(--text-secondary);
  }
</style>
