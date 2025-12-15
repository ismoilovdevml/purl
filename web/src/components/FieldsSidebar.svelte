<script>
  import { createEventDispatcher } from 'svelte';
  import { levelStats, serviceStats, hostStats, namespaceStats, podStats, nodeStats, getLevelColor } from '../stores/logs.js';

  const dispatch = createEventDispatcher();

  let expandedSections = {
    level: true,
    service: true,
    host: true,
    namespace: false,
    pod: false,
    node: false,
  };

  let fieldFilter = '';

  function toggleSection(section) {
    expandedSections[section] = !expandedSections[section];
  }

  function toggleAll(expand) {
    expandedSections = {
      level: expand,
      service: expand,
      host: expand,
      namespace: expand,
      pod: expand,
      node: expand,
    };
  }

  function handleFilter(field, value, exclude = false) {
    const prefix = exclude ? 'NOT ' : '';
    dispatch('filter', { field, value: `${prefix}${field}:${value}` });
  }

  function formatCount(count) {
    if (count >= 1000000) return (count / 1000000).toFixed(1) + 'M';
    if (count >= 1000) return (count / 1000).toFixed(1) + 'K';
    return count;
  }

  function getPercentage(count, stats) {
    const total = stats.reduce((sum, s) => sum + s.count, 0) || 1;
    return (count / total) * 100;
  }

  // Filter fields by search
  $: filteredLevelStats = $levelStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredServiceStats = $serviceStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredHostStats = $hostStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredNamespaceStats = $namespaceStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredPodStats = $podStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredNodeStats = $nodeStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));

  // Check if K8s data exists
  $: hasK8sData = $namespaceStats.length > 0 || $podStats.length > 0 || $nodeStats.length > 0;
</script>

<div class="fields-sidebar">
  <div class="fields-header">
    <h3>Fields</h3>
    <div class="header-actions">
      <button class="action-btn" on:click={() => toggleAll(true)} title="Expand all">
        <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M2 4l4 4 4-4"/></svg>
      </button>
      <button class="action-btn" on:click={() => toggleAll(false)} title="Collapse all">
        <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M2 8l4-4 4 4"/></svg>
      </button>
    </div>
  </div>

  <div class="field-search">
    <svg width="12" height="12" viewBox="0 0 12 12">
      <path fill="currentColor" d="M8.5 5.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Zm-.5 3.2a4 4 0 1 1 .7-.7l2.1 2.1a.5.5 0 0 1-.7.7L8 8.7Z"/>
    </svg>
    <input type="text" bind:value={fieldFilter} placeholder="Filter fields..." />
  </div>

  <!-- Level Section -->
  {#if $levelStats.length > 0}
  <div class="field-section">
    <button class="section-header" on:click={() => toggleSection('level')}>
      <svg class="chevron" class:expanded={expandedSections.level} width="12" height="12" viewBox="0 0 12 12">
        <path fill="currentColor" d="M4.7 10a.5.5 0 0 1-.354-.854L7.293 6 4.346 3.054a.5.5 0 0 1 .708-.708l3.3 3.3a.5.5 0 0 1 0 .708l-3.3 3.3A.5.5 0 0 1 4.7 10Z"/>
      </svg>
      <span class="section-name">level</span>
      <span class="section-count">{$levelStats.length}</span>
    </button>
    {#if expandedSections.level}
      <div class="field-values">
        {#each filteredLevelStats as item}
          <div class="field-value-row">
            <button class="field-value" on:click={() => handleFilter('level', item.value)}>
              <span class="value-dot" style="background: {getLevelColor(item.value)}"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $levelStats).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('level', item.value, true)} title="Exclude">×</button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Service Section -->
  {#if $serviceStats.length > 0}
  <div class="field-section">
    <button class="section-header" on:click={() => toggleSection('service')}>
      <svg class="chevron" class:expanded={expandedSections.service} width="12" height="12" viewBox="0 0 12 12">
        <path fill="currentColor" d="M4.7 10a.5.5 0 0 1-.354-.854L7.293 6 4.346 3.054a.5.5 0 0 1 .708-.708l3.3 3.3a.5.5 0 0 1 0 .708l-3.3 3.3A.5.5 0 0 1 4.7 10Z"/>
      </svg>
      <span class="section-name">service</span>
      <span class="section-count">{$serviceStats.length}</span>
    </button>
    {#if expandedSections.service}
      <div class="field-values">
        {#each filteredServiceStats as item}
          <div class="field-value-row">
            <button class="field-value" on:click={() => handleFilter('service', item.value)}>
              <span class="value-dot" style="background: #58a6ff"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $serviceStats).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('service', item.value, true)} title="Exclude">×</button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Host Section -->
  {#if $hostStats.length > 0}
  <div class="field-section">
    <button class="section-header" on:click={() => toggleSection('host')}>
      <svg class="chevron" class:expanded={expandedSections.host} width="12" height="12" viewBox="0 0 12 12">
        <path fill="currentColor" d="M4.7 10a.5.5 0 0 1-.354-.854L7.293 6 4.346 3.054a.5.5 0 0 1 .708-.708l3.3 3.3a.5.5 0 0 1 0 .708l-3.3 3.3A.5.5 0 0 1 4.7 10Z"/>
      </svg>
      <span class="section-name">host</span>
      <span class="section-count">{$hostStats.length}</span>
    </button>
    {#if expandedSections.host}
      <div class="field-values">
        {#each filteredHostStats as item}
          <div class="field-value-row">
            <button class="field-value" on:click={() => handleFilter('host', item.value)}>
              <span class="value-dot" style="background: #a371f7"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $hostStats).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('host', item.value, true)} title="Exclude">×</button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- K8s Section Divider -->
  {#if hasK8sData}
  <div class="section-divider">
    <span>Kubernetes</span>
  </div>
  {/if}

  <!-- Namespace Section -->
  {#if $namespaceStats.length > 0}
  <div class="field-section">
    <button class="section-header" on:click={() => toggleSection('namespace')}>
      <svg class="chevron" class:expanded={expandedSections.namespace} width="12" height="12" viewBox="0 0 12 12">
        <path fill="currentColor" d="M4.7 10a.5.5 0 0 1-.354-.854L7.293 6 4.346 3.054a.5.5 0 0 1 .708-.708l3.3 3.3a.5.5 0 0 1 0 .708l-3.3 3.3A.5.5 0 0 1 4.7 10Z"/>
      </svg>
      <span class="section-name">namespace</span>
      <span class="section-count">{$namespaceStats.length}</span>
    </button>
    {#if expandedSections.namespace}
      <div class="field-values">
        {#each filteredNamespaceStats as item}
          <div class="field-value-row">
            <button class="field-value" on:click={() => handleFilter('meta.namespace', item.value)}>
              <span class="value-dot" style="background: #f0883e"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $namespaceStats).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('meta.namespace', item.value, true)} title="Exclude">×</button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Pod Section -->
  {#if $podStats.length > 0}
  <div class="field-section">
    <button class="section-header" on:click={() => toggleSection('pod')}>
      <svg class="chevron" class:expanded={expandedSections.pod} width="12" height="12" viewBox="0 0 12 12">
        <path fill="currentColor" d="M4.7 10a.5.5 0 0 1-.354-.854L7.293 6 4.346 3.054a.5.5 0 0 1 .708-.708l3.3 3.3a.5.5 0 0 1 0 .708l-3.3 3.3A.5.5 0 0 1 4.7 10Z"/>
      </svg>
      <span class="section-name">pod</span>
      <span class="section-count">{$podStats.length}</span>
    </button>
    {#if expandedSections.pod}
      <div class="field-values">
        {#each filteredPodStats as item}
          <div class="field-value-row">
            <button class="field-value" on:click={() => handleFilter('meta.pod', item.value)}>
              <span class="value-dot" style="background: #3fb950"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $podStats).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('meta.pod', item.value, true)} title="Exclude">×</button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Node Section -->
  {#if $nodeStats.length > 0}
  <div class="field-section">
    <button class="section-header" on:click={() => toggleSection('node')}>
      <svg class="chevron" class:expanded={expandedSections.node} width="12" height="12" viewBox="0 0 12 12">
        <path fill="currentColor" d="M4.7 10a.5.5 0 0 1-.354-.854L7.293 6 4.346 3.054a.5.5 0 0 1 .708-.708l3.3 3.3a.5.5 0 0 1 0 .708l-3.3 3.3A.5.5 0 0 1 4.7 10Z"/>
      </svg>
      <span class="section-name">node</span>
      <span class="section-count">{$nodeStats.length}</span>
    </button>
    {#if expandedSections.node}
      <div class="field-values">
        {#each filteredNodeStats as item}
          <div class="field-value-row">
            <button class="field-value" on:click={() => handleFilter('meta.node', item.value)}>
              <span class="value-dot" style="background: #bc8cff"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $nodeStats).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('meta.node', item.value, true)} title="Exclude">×</button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}
</div>

<style>
  .fields-sidebar { margin-bottom: 16px; }
  .fields-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
  .fields-header h3 { font-size: 12px; font-weight: 600; text-transform: uppercase; color: #8b949e; letter-spacing: 0.5px; margin: 0; }
  .header-actions { display: flex; gap: 4px; }
  .action-btn { padding: 4px; background: none; border: none; color: #6e7681; cursor: pointer; border-radius: 4px; }
  .action-btn:hover { color: #c9d1d9; background: #21262d; }

  .field-search { display: flex; align-items: center; gap: 8px; padding: 6px 8px; background: #0d1117; border: 1px solid #30363d; border-radius: 6px; margin-bottom: 12px; }
  .field-search svg { color: #6e7681; flex-shrink: 0; }
  .field-search input { flex: 1; background: none; border: none; color: #c9d1d9; font-size: 12px; outline: none; }
  .field-search input::placeholder { color: #6e7681; }

  .section-divider { display: flex; align-items: center; gap: 8px; margin: 12px 0 8px 0; color: #6e7681; font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; }
  .section-divider::before, .section-divider::after { content: ''; flex: 1; height: 1px; background: #30363d; }

  .field-section { margin-bottom: 4px; }
  .section-header { display: flex; align-items: center; gap: 8px; width: 100%; padding: 6px 8px; background: none; border: none; color: #c9d1d9; cursor: pointer; border-radius: 6px; font-size: 13px; font-weight: 500; }
  .section-header:hover { background: #21262d; }
  .section-name { flex: 1; text-align: left; }
  .section-count { font-size: 11px; color: #6e7681; padding: 1px 6px; background: #21262d; border-radius: 10px; }
  .chevron { transition: transform 0.2s; flex-shrink: 0; }
  .chevron.expanded { transform: rotate(90deg); }

  .field-values { padding-left: 12px; }
  .field-value-row { display: flex; align-items: center; gap: 2px; }
  .field-value { display: flex; align-items: center; gap: 6px; flex: 1; padding: 4px 6px; background: none; border: none; color: #c9d1d9; cursor: pointer; border-radius: 4px; font-size: 12px; text-align: left; }
  .field-value:hover { background: #21262d; }

  .exclude-btn { padding: 2px 6px; background: none; border: none; color: #6e7681; cursor: pointer; border-radius: 4px; opacity: 0; font-size: 14px; }
  .field-value-row:hover .exclude-btn { opacity: 1; }
  .exclude-btn:hover { color: #f85149; background: rgba(248, 81, 73, 0.1); }

  .value-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
  .value-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 40px; }
  .value-count { color: #8b949e; font-size: 11px; font-family: 'SFMono-Regular', Consolas, monospace; min-width: 32px; text-align: right; }
  .value-percent { color: #6e7681; font-size: 10px; min-width: 28px; text-align: right; }
</style>
