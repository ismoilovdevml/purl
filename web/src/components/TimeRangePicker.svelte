<script>
  import { createEventDispatcher } from 'svelte';

  export let value = '15m';
  export let customFrom = null;
  export let customTo = null;

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
  let showCustom = false;
  let fromDate = '';
  let fromTime = '';
  let toDate = '';
  let toTime = '';

  function selectRange(range) {
    value = range;
    customFrom = null;
    customTo = null;
    showDropdown = false;
    showCustom = false;
    dispatch('change', { range, from: null, to: null });
  }

  function openCustom() {
    showCustom = true;
    // Set default to last hour
    const now = new Date();
    const hourAgo = new Date(now.getTime() - 60 * 60 * 1000);

    toDate = now.toISOString().split('T')[0];
    toTime = now.toTimeString().slice(0, 5);
    fromDate = hourAgo.toISOString().split('T')[0];
    fromTime = hourAgo.toTimeString().slice(0, 5);
  }

  function applyCustom() {
    if (!fromDate || !fromTime || !toDate || !toTime) return;

    const from = new Date(`${fromDate}T${fromTime}`);
    const to = new Date(`${toDate}T${toTime}`);

    if (from >= to) {
      alert('Start time must be before end time');
      return;
    }

    customFrom = from.toISOString();
    customTo = to.toISOString();
    value = 'custom';
    showDropdown = false;
    showCustom = false;
    dispatch('change', { range: 'custom', from: customFrom, to: customTo });
  }

  function cancelCustom() {
    showCustom = false;
  }

  function toggleDropdown() {
    showDropdown = !showDropdown;
    if (!showDropdown) showCustom = false;
  }

  function handleClickOutside(event) {
    if (!event.target.closest('.time-picker')) {
      showDropdown = false;
      showCustom = false;
    }
  }

  function formatCustomLabel() {
    if (!customFrom || !customTo) return 'Custom';
    const from = new Date(customFrom);
    const to = new Date(customTo);
    const opts = { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false };
    return `${from.toLocaleDateString('en-US', opts)} - ${to.toLocaleDateString('en-US', opts)}`;
  }

  $: currentLabel = value === 'custom'
    ? formatCustomLabel()
    : (ranges.find(r => r.value === value)?.label || value);
</script>

<svelte:window on:click={handleClickOutside} />

<div class="time-picker">
  <button class="picker-btn" on:click|stopPropagation={toggleDropdown}>
    <svg width="16" height="16" viewBox="0 0 16 16">
      <path fill="currentColor" d="M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0Zm0 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM8 3a.75.75 0 0 1 .75.75v3.69l2.28 2.28a.75.75 0 0 1-1.06 1.06L7.22 8.03A.75.75 0 0 1 7 7.5v-3.75A.75.75 0 0 1 8 3Z"/>
    </svg>
    <span class="label-text">{currentLabel}</span>
    <svg class="chevron" width="12" height="12" viewBox="0 0 12 12">
      <path fill="currentColor" d="M6 8.825a.5.5 0 0 1-.354-.146l-4-4a.5.5 0 0 1 .708-.708L6 7.617l3.646-3.646a.5.5 0 0 1 .708.708l-4 4A.5.5 0 0 1 6 8.825Z"/>
    </svg>
  </button>

  {#if showDropdown}
    <div class="dropdown">
      {#if showCustom}
        <div class="custom-range">
          <div class="custom-header">
            <span>Custom Time Range</span>
          </div>

          <div class="datetime-group">
            <label for="from-date">From</label>
            <div class="datetime-inputs">
              <input id="from-date" type="date" bind:value={fromDate} />
              <input id="from-time" type="time" bind:value={fromTime} aria-label="From time" />
            </div>
          </div>

          <div class="datetime-group">
            <label for="to-date">To</label>
            <div class="datetime-inputs">
              <input id="to-date" type="date" bind:value={toDate} />
              <input id="to-time" type="time" bind:value={toTime} aria-label="To time" />
            </div>
          </div>

          <div class="custom-actions">
            <button class="btn-cancel" on:click|stopPropagation={cancelCustom}>Cancel</button>
            <button class="btn-apply" on:click|stopPropagation={applyCustom}>Apply</button>
          </div>
        </div>
      {:else}
        <div class="quick-ranges">
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
        <div class="dropdown-divider"></div>
        <button class="dropdown-item custom-btn" on:click|stopPropagation={openCustom}>
          <svg width="14" height="14" viewBox="0 0 16 16">
            <path fill="currentColor" d="M4.75 0a.75.75 0 0 1 .75.75V2h5V.75a.75.75 0 0 1 1.5 0V2H14a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1h2.25V.75A.75.75 0 0 1 4.75 0ZM2.5 6v8.5h11V6h-11Z"/>
          </svg>
          Custom range...
        </button>
      {/if}
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

  .label-text {
    max-width: 200px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .chevron {
    margin-left: 4px;
    flex-shrink: 0;
  }

  .dropdown {
    position: absolute;
    top: 100%;
    right: 0;
    margin-top: 4px;
    min-width: 220px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 50;
    overflow: hidden;
  }

  .quick-ranges {
    max-height: 300px;
    overflow-y: auto;
  }

  .dropdown-item {
    display: flex;
    align-items: center;
    gap: 8px;
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

  .dropdown-divider {
    height: 1px;
    background: #30363d;
    margin: 4px 0;
  }

  .custom-btn {
    color: #58a6ff;
  }

  .custom-btn svg {
    opacity: 0.8;
  }

  .custom-range {
    padding: 16px;
  }

  .custom-header {
    font-size: 13px;
    font-weight: 600;
    color: #c9d1d9;
    margin-bottom: 16px;
    padding-bottom: 12px;
    border-bottom: 1px solid #30363d;
  }

  .datetime-group {
    margin-bottom: 12px;
  }

  .datetime-group label {
    display: block;
    font-size: 12px;
    color: #8b949e;
    margin-bottom: 6px;
  }

  .datetime-inputs {
    display: flex;
    gap: 8px;
  }

  .datetime-inputs input {
    flex: 1;
    padding: 8px 10px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 13px;
    font-family: inherit;
  }

  .datetime-inputs input:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .datetime-inputs input[type="date"] {
    flex: 1.2;
  }

  .datetime-inputs input[type="time"] {
    flex: 0.8;
  }

  .custom-actions {
    display: flex;
    gap: 8px;
    margin-top: 16px;
    padding-top: 12px;
    border-top: 1px solid #30363d;
  }

  .btn-cancel, .btn-apply {
    flex: 1;
    padding: 8px 16px;
    border-radius: 6px;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    border: none;
  }

  .btn-cancel {
    background: #21262d;
    color: #c9d1d9;
  }

  .btn-cancel:hover {
    background: #30363d;
  }

  .btn-apply {
    background: #238636;
    color: #ffffff;
  }

  .btn-apply:hover {
    background: #2ea043;
  }

  /* Dark theme for date/time inputs */
  input[type="date"]::-webkit-calendar-picker-indicator,
  input[type="time"]::-webkit-calendar-picker-indicator {
    filter: invert(0.8);
    cursor: pointer;
  }
</style>
