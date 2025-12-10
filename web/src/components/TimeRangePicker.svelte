<script>
  import { createEventDispatcher } from 'svelte';

  export let value = '15m';

  const dispatch = createEventDispatcher();

  const ranges = [
    { value: '5m', label: 'Last 5 minutes' },
    { value: '15m', label: 'Last 15 minutes' },
    { value: '30m', label: 'Last 30 minutes' },
    { value: '1h', label: 'Last 1 hour' },
    { value: '4h', label: 'Last 4 hours' },
    { value: '12h', label: 'Last 12 hours' },
    { value: '24h', label: 'Last 24 hours' },
    { value: '7d', label: 'Last 7 days' },
    { value: '30d', label: 'Last 30 days' },
  ];

  let showDropdown = false;

  function selectRange(range) {
    value = range;
    showDropdown = false;
    dispatch('change', range);
  }

  function toggleDropdown() {
    showDropdown = !showDropdown;
  }

  function handleClickOutside(event) {
    if (!event.target.closest('.time-picker')) {
      showDropdown = false;
    }
  }

  $: currentLabel = ranges.find(r => r.value === value)?.label || value;
</script>

<svelte:window on:click={handleClickOutside} />

<div class="time-picker">
  <button class="picker-btn" on:click|stopPropagation={toggleDropdown}>
    <svg width="16" height="16" viewBox="0 0 16 16">
      <path fill="currentColor" d="M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0Zm0 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM8 3a.75.75 0 0 1 .75.75v3.69l2.28 2.28a.75.75 0 0 1-1.06 1.06L7.22 8.03A.75.75 0 0 1 7 7.5v-3.75A.75.75 0 0 1 8 3Z"/>
    </svg>
    <span>{currentLabel}</span>
    <svg class="chevron" width="12" height="12" viewBox="0 0 12 12">
      <path fill="currentColor" d="M6 8.825a.5.5 0 0 1-.354-.146l-4-4a.5.5 0 0 1 .708-.708L6 7.617l3.646-3.646a.5.5 0 0 1 .708.708l-4 4A.5.5 0 0 1 6 8.825Z"/>
    </svg>
  </button>

  {#if showDropdown}
    <div class="dropdown">
      {#each ranges as range}
        <button
          class="dropdown-item"
          class:active={value === range.value}
          on:click={() => selectRange(range.value)}
        >
          {range.label}
        </button>
      {/each}
    </div>
  {/if}
</div>

<style>
  .time-picker {
    position: relative;
  }

  .picker-btn {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 14px;
  }

  .picker-btn:hover {
    background: #30363d;
  }

  .chevron {
    margin-left: 4px;
  }

  .dropdown {
    position: absolute;
    top: 100%;
    right: 0;
    margin-top: 4px;
    min-width: 180px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 50;
    overflow: hidden;
  }

  .dropdown-item {
    display: block;
    width: 100%;
    padding: 10px 16px;
    background: none;
    border: none;
    color: #c9d1d9;
    text-align: left;
    cursor: pointer;
    font-size: 14px;
  }

  .dropdown-item:hover {
    background: #21262d;
  }

  .dropdown-item.active {
    background: #388bfd26;
    color: #58a6ff;
  }
</style>
