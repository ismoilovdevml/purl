<script>
  import Icon from './ui/Icon.svelte';
  import CustomRangeForm from './timerange/CustomRangeForm.svelte';
  import { clock, caretDown, calendar } from './ui/icons.js';
  import { stopPropagation } from '../utils/dom.js';

  /**
   * `value` / `customFrom` / `customTo` are reassigned locally when the user
   * picks a range; the parent learns about it through `onchange` and passes the
   * new value back down.
   * @type {{
   *   value?: string,
   *   customFrom?: string | null,
   *   customTo?: string | null,
   *   onchange?: (e: { range: string, from: string | null, to: string | null }) => void,
   * }}
   */
  let { value = '15m', customFrom = null, customTo = null, onchange } = $props();

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

  let showDropdown = $state(false);
  let showCustom = $state(false);

  function selectRange(range) {
    value = range;
    customFrom = null;
    customTo = null;
    showDropdown = false;
    showCustom = false;
    onchange?.({ range, from: null, to: null });
  }

  function openCustom() {
    showCustom = true;
  }

  function applyCustom(from, to) {
    customFrom = from;
    customTo = to;
    value = 'custom';
    showDropdown = false;
    showCustom = false;
    onchange?.({ range: 'custom', from: customFrom, to: customTo });
  }

  function cancelCustom() {
    showCustom = false;
  }

  function toggleDropdown() {
    showDropdown = !showDropdown;
    if (!showDropdown) {
      showCustom = false;
    }
  }

  function handleKeydown(event) {
    if (event.key === 'Escape') {
      showDropdown = false;
      showCustom = false;
    } else if (event.key === 'Enter' || event.key === ' ') {
      if (!showDropdown) {
        event.preventDefault();
        showDropdown = true;
      }
    } else if (event.key === 'ArrowDown' && showDropdown) {
      event.preventDefault();
      // Focus first item in dropdown
      const firstItem = document.querySelector('.dropdown-item');
      if (firstItem) firstItem.focus();
    }
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

  const currentLabel = $derived(value === 'custom'
    ? formatCustomLabel()
    : (ranges.find(r => r.value === value)?.label || value));
</script>

<svelte:window onclick={handleClickOutside} />

<div class="time-picker" role="group" aria-label="Time range selector">
  <button
    class="picker-btn"
    onclick={stopPropagation(toggleDropdown)}
    onkeydown={handleKeydown}
    aria-haspopup="listbox"
    aria-expanded={showDropdown}
    aria-label="Select time range: {currentLabel}"
  >
    <Icon icon={clock} size={16} strokeWidth={2.25} />
    <span class="label-text">{currentLabel}</span>
    <Icon icon={caretDown} class="chevron" size={12} />
  </button>

  {#if showDropdown}
    <div class="dropdown" role="listbox" aria-label="Time range options">
      {#if showCustom}
        <CustomRangeForm onapply={applyCustom} oncancel={cancelCustom} />
      {:else}
        <div class="quick-ranges">
          {#each ranges as range (range.value)}
            <button
              class="dropdown-item"
              class:active={value === range.value}
              onclick={() => selectRange(range.value)}
              role="option"
              aria-selected={value === range.value}
            >
              {range.label}
            </button>
          {/each}
        </div>
        <div class="dropdown-divider"></div>
        <button class="dropdown-item custom-btn" onclick={stopPropagation(openCustom)}>
          <Icon icon={calendar} size={14} strokeWidth={2.5} />
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

  /* :global — the class is forwarded onto the SVG that Icon renders. */
  .picker-btn :global(.chevron) {
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

  .custom-btn :global(svg) {
    opacity: 0.8;
  }
</style>
