<script>
  import { onMount, onDestroy } from 'svelte';
  import Icon from './ui/Icon.svelte';
  import EmptyState from './ui/EmptyState.svelte';
  import PodHealthHeader from './k8s/PodHealthHeader.svelte';
  import PodHealthStats from './k8s/PodHealthStats.svelte';
  import UnhealthyPodsTable from './k8s/UnhealthyPodsTable.svelte';
  import { alertCircle, activity, checkCircle } from './ui/icons.js';
  import {
    podHealth,
    healthSummary,
    healthLoading,
    healthError,
    fetchPodHealth,
    startAutoRefresh,
    stopAutoRefresh,
  } from '../stores/k8sHealth.js';

  let selectedHours = $state(1);
  let autoRefresh = $state(true);
  let sortColumn = $state('count');
  let sortDirection = $state('desc');

  // Sorted pods
  const sortedPods = $derived.by(() => {
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
  });

  // Summary entries from store
  const summaryEntries = $derived(Object.entries($healthSummary.summary || {}));
  const totalUnhealthy = $derived($healthSummary.total_unhealthy || 0);

  // No-data signal from the backend: when there are zero K8s audit records the
  // health response reports has_data false/0. Distinguish this from a genuine
  // all-clear ("0 unhealthy") so we don't show a false green summary.
  // If the field is absent (older backend) we keep today's behavior.
  const noK8sData = $derived($healthSummary.has_data === false || $healthSummary.has_data === 0);

  function handleSort(column) {
    if (sortColumn === column) {
      sortDirection = sortDirection === 'asc' ? 'desc' : 'asc';
    } else {
      sortColumn = column;
      sortDirection = column === 'count' || column === 'last_seen' ? 'desc' : 'asc';
    }
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
  <PodHealthHeader
    showBadge={!$healthLoading && !$healthError && !noK8sData}
    {totalUnhealthy}
    {selectedHours}
    {autoRefresh}
    loading={$healthLoading}
    ontimerange={handleTimeRange}
    ontoggleautorefresh={toggleAutoRefresh}
    onrefresh={() => fetchPodHealth(selectedHours)}
  />

  <!-- Error state -->
  {#if $healthError}
    <div class="error-banner">
      <Icon icon={alertCircle} size={16} />
      <span>{$healthError}</span>
      <button class="error-retry" onclick={() => fetchPodHealth(selectedHours)}>Retry</button>
    </div>

  <!-- Loading state (initial only) -->
  {:else if $healthLoading && $podHealth.pods.length === 0 && summaryEntries.length === 0}
    <div class="loading-state">
      <div class="spinner"></div>
      <span>Scanning pod health...</span>
    </div>

  <!-- No-data state: K8s audit ingestion has produced no records yet. -->
  {:else if noK8sData}
    <EmptyState icon={activity} title="No Kubernetes audit data yet" size="lg">
      Purl has not received any K8s audit records. Enable K8s audit log ingestion for your cluster to see pod health here.
    </EmptyState>

  {:else}
    <PodHealthStats {summaryEntries} {totalUnhealthy} />

    <!-- Pods table or empty state -->
    {#if sortedPods.length > 0}
      <UnhealthyPodsTable
        pods={sortedPods}
        total={$podHealth.total || sortedPods.length}
        loading={$healthLoading}
        {sortColumn}
        {sortDirection}
        onsort={handleSort}
      />

    <!-- Empty state: all pods healthy -->
    {:else if !$healthLoading}
      <EmptyState icon={checkCircle} title="All Pods Healthy" size="lg" tone="success">
        No unhealthy pods detected in the last {selectedHours >= 168 ? '7 days' : selectedHours >= 24 ? '24 hours' : selectedHours + ' hour' + (selectedHours !== 1 ? 's' : '')}
      </EmptyState>
    {/if}
  {/if}
</div>

<style>
  .k8s-page {
    padding: 16px 20px;
    overflow-y: auto;
    height: calc(100vh - 60px);
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
</style>
