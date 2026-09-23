<!--
  PodHealthStats
  Summary card row of the K8s Pod Health page: total unhealthy pods, one card
  per error type (coloured by type), or a single "All Healthy" card.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { checkCircle } from '../ui/icons.js';
  import { getErrorStyle } from '../../utils/k8sErrorStyles.js';

  let {
    /** [errorType, count | { pod_count, total_errors }] pairs from the health summary */
    summaryEntries = [],
    /** Number of unhealthy pods */
    totalUnhealthy = 0,
  } = $props();
</script>

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
        <Icon icon={checkCircle} size={24} color="#3fb950" />
      </div>
      <div class="stat-label">All Healthy</div>
    </div>
  {/if}
</div>

<style>
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

  /* Responsive */
  @media (max-width: 1200px) {
    .stats-row {
      grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
    }
  }

  @media (max-width: 768px) {
    .stats-row {
      grid-template-columns: repeat(2, 1fr);
    }
  }
</style>
