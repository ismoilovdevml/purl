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
  import Icon from './Icon.svelte';
  import EnvBadge from './EnvBadge.svelte';
  import { chevronDown } from './icons.js';

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

  /** Field is pinned by a server environment variable — see Input.svelte */
  export let envLocked = false;

  $: isDisabled = disabled || envLocked;

  const dispatch = createEventDispatcher();

  function handleChange(event) {
    value = event.target.value;
    dispatch('change', { value });
  }
</script>

<div class="select-wrapper" class:full-width={fullWidth}>
  {#if label || envLocked}
    <span class="select-label">
      {label}
      <EnvBadge locked={envLocked} />
    </span>
  {/if}

  <div class="select-container" class:has-error={error} class:disabled={isDisabled} class:size-sm={size === 'sm'} class:size-lg={size === 'lg'}>
    <select
      class="select-field"
      disabled={isDisabled}
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
      <Icon icon={chevronDown} size={16} strokeWidth={2.25} />
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
    gap: var(--space-1);
  }

  .select-wrapper.full-width {
    width: 100%;
  }

  .select-label {
    font-size: var(--text-sm);
    font-weight: 500;
    color: var(--text-secondary);
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
    padding: 0 var(--space-8) 0 var(--space-3);
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    font-size: var(--text-base);
    color: var(--text-primary);
    cursor: pointer;
    transition: var(--transition-fast);
  }

  .select-field:focus {
    border-color: var(--color-primary);
    box-shadow: 0 0 0 2px var(--color-primary-bg);
  }

  .select-field:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    background: var(--bg-secondary);
  }

  /* Sizes */
  .select-container.size-sm .select-field {
    height: 28px;
    padding: 0 var(--space-6) 0 var(--space-2);
    font-size: var(--text-sm);
  }

  .select-container.size-lg .select-field {
    height: 44px;
  }

  .select-container.has-error .select-field {
    border-color: var(--color-error);
  }

  .select-icon {
    position: absolute;
    right: var(--space-3);
    display: flex;
    align-items: center;
    color: var(--text-muted);
    pointer-events: none;
  }

  .select-container.size-sm .select-icon {
    right: var(--space-2);
  }

  .select-icon :global(svg) {
    width: 16px;
    height: 16px;
  }

  .select-error {
    font-size: var(--text-xs);
    color: var(--color-error);
  }

  /* Option styling */
  .select-field option {
    background: var(--bg-secondary);
    color: var(--text-primary);
  }

  .select-field option:disabled {
    color: var(--text-muted);
  }
</style>
