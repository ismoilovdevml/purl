<!--
  ClusterSelector Component
  Dropdown for selecting a Kubernetes cluster to filter logs.
  Shows available clusters from meta.cluster field.
-->
<script>
  import { createEventDispatcher } from 'svelte';
  import { selectedCluster, clusters, clustersLoading } from '../../stores/cluster.js';
  import Icon from './Icon.svelte';

  const dispatch = createEventDispatcher();

  function handleChange(event) {
    const value = event.target.value;
    selectedCluster.set(value);
    dispatch('change', { cluster: value });
  }
</script>

<div class="cluster-selector" title="Filter logs by cluster">
  <Icon name="globe" size={16} />
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
  <Icon name="chevron-down" size={12} class="chevron" />
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

  .cluster-selector :global(svg:first-child) {
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

  .cluster-selector :global(.chevron) {
    position: absolute;
    right: 8px;
    pointer-events: none;
    color: #6e7681;
    flex-shrink: 0;
  }
</style>
