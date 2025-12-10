<script>
  import { createEventDispatcher } from 'svelte';
  import { levelStats, serviceStats, hostStats, getLevelColor } from '../stores/logs.js';

  const dispatch = createEventDispatcher();

  let expandedSections = {
    level: true,
    service: true,
    host: false,
  };

  function toggleSection(section) {
    expandedSections[section] = !expandedSections[section];
  }

  function handleFilter(field, value) {
    dispatch('filter', { field, value });
  }

  function formatCount(count) {
    if (count >= 1000000) return (count / 1000000).toFixed(1) + 'M';
    if (count >= 1000) return (count / 1000).toFixed(1) + 'K';
    return count;
  }
</script>

<div class="fields-sidebar">
  <h3>Fields</h3>

  <!-- Level Section -->
  <div class="field-section">
    <button class="section-header" on:click={() => toggleSection('level')}>
      <svg class="chevron" class:expanded={expandedSections.level} width="12" height="12" viewBox="0 0 12 12">
        <path fill="currentColor" d="M4.7 10a.5.5 0 0 1-.354-.854L7.293 6 4.346 3.054a.5.5 0 0 1 .708-.708l3.3 3.3a.5.5 0 0 1 0 .708l-3.3 3.3A.5.5 0 0 1 4.7 10Z"/>
      </svg>
      <span>level</span>
    </button>

    {#if expandedSections.level}
      <div class="field-values">
        {#each $levelStats as item}
          <button class="field-value" on:click={() => handleFilter('level', item.value)}>
            <span class="value-dot" style="background: {getLevelColor(item.value)}"></span>
            <span class="value-name">{item.value}</span>
            <span class="value-count">{formatCount(item.count)}</span>
          </button>
        {/each}
        {#if $levelStats.length === 0}
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
      <span>service</span>
    </button>

    {#if expandedSections.service}
      <div class="field-values">
        {#each $serviceStats as item}
          <button class="field-value" on:click={() => handleFilter('service', item.value)}>
            <span class="value-dot" style="background: #58a6ff"></span>
            <span class="value-name">{item.value}</span>
            <span class="value-count">{formatCount(item.count)}</span>
          </button>
        {/each}
        {#if $serviceStats.length === 0}
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
      <span>host</span>
    </button>

    {#if expandedSections.host}
      <div class="field-values">
        {#each $hostStats as item}
          <button class="field-value" on:click={() => handleFilter('host', item.value)}>
            <span class="value-dot" style="background: #a371f7"></span>
            <span class="value-name">{item.value}</span>
            <span class="value-count">{formatCount(item.count)}</span>
          </button>
        {/each}
        {#if $hostStats.length === 0}
          <div class="empty">No data</div>
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .fields-sidebar h3 {
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    color: #8b949e;
    margin-bottom: 16px;
    letter-spacing: 0.5px;
  }

  .field-section {
    margin-bottom: 8px;
  }

  .section-header {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px;
    background: none;
    border: none;
    color: #c9d1d9;
    cursor: pointer;
    border-radius: 6px;
    font-size: 14px;
    font-weight: 500;
  }

  .section-header:hover {
    background: #21262d;
  }

  .chevron {
    transition: transform 0.2s;
  }

  .chevron.expanded {
    transform: rotate(90deg);
  }

  .field-values {
    padding-left: 20px;
  }

  .field-value {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 6px 8px;
    background: none;
    border: none;
    color: #c9d1d9;
    cursor: pointer;
    border-radius: 4px;
    font-size: 13px;
    text-align: left;
  }

  .field-value:hover {
    background: #21262d;
  }

  .value-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .value-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .value-count {
    color: #8b949e;
    font-size: 12px;
    font-family: 'SFMono-Regular', Consolas, monospace;
  }

  .empty {
    padding: 8px;
    color: #6e7681;
    font-size: 13px;
    font-style: italic;
  }
</style>
