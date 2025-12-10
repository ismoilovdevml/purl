<script>
  import { createEventDispatcher } from 'svelte';
  import { levelStats, serviceStats, hostStats, getLevelColor, total } from '../stores/logs.js';

  const dispatch = createEventDispatcher();

  let expandedSections = {
    level: true,
    service: true,
    host: true,
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

  function getPercentage(count) {
    const t = $total || 1;
    return Math.min(100, (count / t) * 100);
  }

  // Filter fields by search
  $: filteredLevelStats = $levelStats.filter(s =>
    !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase())
  );
  $: filteredServiceStats = $serviceStats.filter(s =>
    !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase())
  );
  $: filteredHostStats = $hostStats.filter(s =>
    !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase())
  );

  // Get max count for bar scaling
  $: maxLevelCount = Math.max(...$levelStats.map(s => s.count), 1);
  $: maxServiceCount = Math.max(...$serviceStats.map(s => s.count), 1);
  $: maxHostCount = Math.max(...$hostStats.map(s => s.count), 1);
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

  <!-- Field search -->
  <div class="field-search">
    <svg width="12" height="12" viewBox="0 0 12 12">
      <path fill="currentColor" d="M8.5 5.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Zm-.5 3.2a4 4 0 1 1 .7-.7l2.1 2.1a.5.5 0 0 1-.7.7L8 8.7Z"/>
    </svg>
    <input type="text" bind:value={fieldFilter} placeholder="Filter fields..." />
  </div>

  <!-- Level Section -->
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
              <div class="value-bar-container">
                <div class="value-bar" style="width: {(item.count / maxLevelCount) * 100}%; background: {getLevelColor(item.value)}40"></div>
              </div>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('level', item.value, true)} title="Exclude">
              <svg width="10" height="10" viewBox="0 0 10 10"><path stroke="currentColor" stroke-width="1.5" d="M2 2l6 6M8 2L2 8"/></svg>
            </button>
          </div>
        {/each}
        {#if filteredLevelStats.length === 0}
          <div class="empty">No data</div>
        {/if}
      </div>
    {/if}
  </div>

  <!-- Service Section -->
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
              <div class="value-bar-container">
                <div class="value-bar" style="width: {(item.count / maxServiceCount) * 100}%; background: #58a6ff40"></div>
              </div>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('service', item.value, true)} title="Exclude">
              <svg width="10" height="10" viewBox="0 0 10 10"><path stroke="currentColor" stroke-width="1.5" d="M2 2l6 6M8 2L2 8"/></svg>
            </button>
          </div>
        {/each}
        {#if filteredServiceStats.length === 0}
          <div class="empty">No data</div>
        {/if}
      </div>
    {/if}
  </div>

  <!-- Host Section -->
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
              <div class="value-bar-container">
                <div class="value-bar" style="width: {(item.count / maxHostCount) * 100}%; background: #a371f740"></div>
              </div>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count).toFixed(0)}%</span>
            </button>
            <button class="exclude-btn" on:click|stopPropagation={() => handleFilter('host', item.value, true)} title="Exclude">
              <svg width="10" height="10" viewBox="0 0 10 10"><path stroke="currentColor" stroke-width="1.5" d="M2 2l6 6M8 2L2 8"/></svg>
            </button>
          </div>
        {/each}
        {#if filteredHostStats.length === 0}
          <div class="empty">No data</div>
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .fields-sidebar {
    margin-bottom: 16px;
  }

  .fields-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }

  .fields-header h3 {
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    color: #8b949e;
    letter-spacing: 0.5px;
    margin: 0;
  }

  .header-actions {
    display: flex;
    gap: 4px;
  }

  .action-btn {
    padding: 4px;
    background: none;
    border: none;
    color: #6e7681;
    cursor: pointer;
    border-radius: 4px;
  }

  .action-btn:hover {
    color: #c9d1d9;
    background: #21262d;
  }

  .field-search {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 8px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    margin-bottom: 12px;
  }

  .field-search svg {
    color: #6e7681;
    flex-shrink: 0;
  }

  .field-search input {
    flex: 1;
    background: none;
    border: none;
    color: #c9d1d9;
    font-size: 12px;
    outline: none;
  }

  .field-search input::placeholder {
    color: #6e7681;
  }

  .field-section {
    margin-bottom: 4px;
  }

  .section-header {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 6px 8px;
    background: none;
    border: none;
    color: #c9d1d9;
    cursor: pointer;
    border-radius: 6px;
    font-size: 13px;
    font-weight: 500;
  }

  .section-header:hover {
    background: #21262d;
  }

  .section-name {
    flex: 1;
    text-align: left;
  }

  .section-count {
    font-size: 11px;
    color: #6e7681;
    padding: 1px 6px;
    background: #21262d;
    border-radius: 10px;
  }

  .chevron {
    transition: transform 0.2s;
    flex-shrink: 0;
  }

  .chevron.expanded {
    transform: rotate(90deg);
  }

  .field-values {
    padding-left: 12px;
  }

  .field-value-row {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  .field-value {
    display: flex;
    align-items: center;
    gap: 6px;
    flex: 1;
    padding: 4px 6px;
    background: none;
    border: none;
    color: #c9d1d9;
    cursor: pointer;
    border-radius: 4px;
    font-size: 12px;
    text-align: left;
  }

  .field-value:hover {
    background: #21262d;
  }

  .exclude-btn {
    padding: 4px;
    background: none;
    border: none;
    color: #6e7681;
    cursor: pointer;
    border-radius: 4px;
    opacity: 0;
    transition: opacity 0.15s;
  }

  .field-value-row:hover .exclude-btn {
    opacity: 1;
  }

  .exclude-btn:hover {
    color: #f85149;
    background: rgba(248, 81, 73, 0.1);
  }

  .value-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .value-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 40px;
  }

  .value-bar-container {
    width: 40px;
    height: 8px;
    background: #21262d;
    border-radius: 2px;
    overflow: hidden;
    flex-shrink: 0;
  }

  .value-bar {
    height: 100%;
    border-radius: 2px;
    transition: width 0.3s ease;
  }

  .value-count {
    color: #8b949e;
    font-size: 11px;
    font-family: 'SFMono-Regular', Consolas, monospace;
    min-width: 32px;
    text-align: right;
  }

  .value-percent {
    color: #6e7681;
    font-size: 10px;
    min-width: 28px;
    text-align: right;
  }

  .empty {
    padding: 8px;
    color: #6e7681;
    font-size: 12px;
    font-style: italic;
  }
</style>
