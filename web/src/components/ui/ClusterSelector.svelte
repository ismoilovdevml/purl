<!--
  ClusterSelector Component
  Dropdown for selecting a Kubernetes cluster to filter logs.
  Shows available clusters from meta.cluster field.
-->
<script>
  import { createEventDispatcher } from 'svelte';
  import { selectedCluster, clusters, clustersLoading } from '../../stores/cluster.js';

  const dispatch = createEventDispatcher();

  function handleChange(event) {
    const value = event.target.value;
    selectedCluster.set(value);
    dispatch('change', { cluster: value });
  }
</script>

<div class="cluster-selector" title="Filter logs by cluster">
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
    <circle cx="12" cy="12" r="10" />
    <path d="M12 2a14.5 14.5 0 004 10 14.5 14.5 0 00-4 10 14.5 14.5 0 00-4-10 14.5 14.5 0 004-10" />
    <path d="M2 12h20" />
  </svg>
  <select
    class="cluster-select"
    value={$selectedCluster}
    on:change={handleChange}
    disabled={$clustersLoading}
    aria-label="Select cluster"
  >
    <option value="all">All Clusters</option>
    {#each $clusters as cluster}
      <option value={cluster}>{cluster}</option>
    {/each}
  </select>
  <svg class="chevron" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
    <path fill="currentColor" d="M6 8.825a.5.5 0 0 1-.354-.146l-4-4a.5.5 0 0 1 .708-.708L6 7.617l3.646-3.646a.5.5 0 0 1 .708.708l-4 4A.5.5 0 0 1 6 8.825Z"/>
  </svg>
</div>

<style>
  .cluster-selector {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #8b949e;
    height: 36px;
    position: relative;
  }

  .cluster-selector:hover {
    background: #30363d;
  }

  .cluster-selector svg:first-child {
    flex-shrink: 0;
    opacity: 0.7;
  }

  .cluster-select {
    appearance: none;
    background: transparent;
    border: none;
    color: #c9d1d9;
    font-size: 13px;
    cursor: pointer;
    padding: 0 16px 0 0;
    outline: none;
    min-width: 100px;
    max-width: 180px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .cluster-select:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .cluster-select option {
    background: #161b22;
    color: #c9d1d9;
  }

  .chevron {
    position: absolute;
    right: 8px;
    pointer-events: none;
    color: #6e7681;
    flex-shrink: 0;
  }
</style>
