<!--
  Select Component
  Dropdown select with customizable options

  Usage:
  <Select bind:value={selected} options={[
    { value: 'a', label: 'Option A' },
    { value: 'b', label: 'Option B' }
  ]} />
-->
<script>
  import { createEventDispatcher } from 'svelte';

  /** Selected value */
  export let value = '';

  /** Options array */
  export let options = []; // { value, label, disabled? }

  /** Label text */
  export let label = '';

  /** Placeholder text */
  export let placeholder = 'Select...';

  /** Disabled state */
  export let disabled = false;

  /** Size */
  export let size = 'md'; // sm, md, lg

  /** Full width */
  export let fullWidth = false;

  /** Error message */
  export let error = '';

  const dispatch = createEventDispatcher();

  function handleChange(event) {
    value = event.target.value;
    dispatch('change', { value });
  }
</script>

<div class="select-wrapper" class:full-width={fullWidth}>
  {#if label}
    <span class="select-label">{label}</span>
  {/if}

  <div class="select-container" class:has-error={error} class:disabled class:size-sm={size === 'sm'} class:size-lg={size === 'lg'}>
    <select
      class="select-field"
      {disabled}
      bind:value
      on:change={handleChange}
    >
      {#if placeholder}
        <option value="" disabled>{placeholder}</option>
      {/if}
      {#each options as option}
        <option value={option.value} disabled={option.disabled}>
          {option.label}
        </option>
      {/each}
    </select>

    <span class="select-icon">
      <svg viewBox="0 0 16 16" fill="currentColor">
        <path d="M4.427 6.427l3.396 3.396a.25.25 0 00.354 0l3.396-3.396A.25.25 0 0011.396 6H4.604a.25.25 0 00-.177.427z" />
      </svg>
    </span>
  </div>

  {#if error}
    <span class="select-error">{error}</span>
  {/if}
</div>

<style>
  .select-wrapper {
    display: flex;
    flex-direction: column;
    gap: var(--space-1, 4px);
  }

  .select-wrapper.full-width {
    width: 100%;
  }

  .select-label {
    font-size: var(--text-sm, 12px);
    font-weight: 500;
    color: var(--text-secondary, #8b949e);
  }

  .select-container {
    position: relative;
    display: flex;
    align-items: center;
  }

  .select-field {
    appearance: none;
    width: 100%;
    height: 36px;
    padding: 0 var(--space-8, 32px) 0 var(--space-3, 12px);
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-md, 6px);
    font-size: var(--text-base, 13px);
    color: var(--text-primary, #c9d1d9);
    cursor: pointer;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .select-field:focus {
    outline: none;
    border-color: var(--color-primary, #58a6ff);
    box-shadow: 0 0 0 2px var(--color-primary-bg, rgba(88, 166, 255, 0.15));
  }

  .select-field:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    background: var(--bg-secondary, #161b22);
  }

  /* Sizes */
  .select-container.size-sm .select-field {
    height: 28px;
    padding: 0 var(--space-6, 24px) 0 var(--space-2, 8px);
    font-size: var(--text-sm, 12px);
  }

  .select-container.size-lg .select-field {
    height: 44px;
  }

  .select-container.has-error .select-field {
    border-color: var(--color-error, #f85149);
  }

  .select-icon {
    position: absolute;
    right: var(--space-3, 12px);
    display: flex;
    align-items: center;
    color: var(--text-muted, #6e7681);
    pointer-events: none;
  }

  .select-container.size-sm .select-icon {
    right: var(--space-2, 8px);
  }

  .select-icon svg {
    width: 16px;
    height: 16px;
  }

  .select-error {
    font-size: var(--text-xs, 11px);
    color: var(--color-error, #f85149);
  }

  /* Option styling */
  .select-field option {
    background: var(--bg-secondary, #161b22);
    color: var(--text-primary, #c9d1d9);
  }

  .select-field option:disabled {
    color: var(--text-muted, #6e7681);
  }
</style>
