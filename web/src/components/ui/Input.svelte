<!--
  Input Component
  Flexible input with label, validation, and icons

  Usage:
  <Input bind:value={email} label="Email" type="email" placeholder="Enter email" />
  <Input bind:value={search} placeholder="Search..." icon>
    <svg slot="icon">...</svg>
  </Input>
-->
<script>
  import { createEventDispatcher } from 'svelte';

  /** Input type */
  export let type = 'text';

  /** Input value */
  export let value = '';

  /** Label text */
  export let label = '';

  /** Placeholder text */
  export let placeholder = '';

  /** Error message */
  export let error = '';

  /** Helper text */
  export let helper = '';

  /** Disabled state */
  export let disabled = false;

  /** Required field */
  export let required = false;

  /** Input size */
  export let size = 'md'; // sm, md, lg

  /** Full width */
  export let fullWidth = false;

  /** Input name */
  export let name = '';

  /** Autocomplete */
  export let autocomplete = 'off';

  /** Min value (for number) */
  export let min = undefined;

  /** Max value (for number) */
  export let max = undefined;

  /** Step (for number) */
  export let step = undefined;

  /** Readonly */
  export let readonly = false;

  const dispatch = createEventDispatcher();

  function handleInput(event) {
    value = event.target.value;
    dispatch('input', { value });
  }

  function handleChange(event) {
    dispatch('change', { value: event.target.value });
  }

  function handleFocus(event) {
    dispatch('focus', event);
  }

  function handleBlur(event) {
    dispatch('blur', event);
  }

  function handleKeydown(event) {
    dispatch('keydown', event);
    if (event.key === 'Enter') {
      dispatch('enter', { value });
    }
  }
</script>

<div class="input-wrapper" class:full-width={fullWidth}>
  {#if label}
    <span class="input-label" class:required>
      {label}
    </span>
  {/if}

  <div class="input-container" class:has-error={error} class:disabled class:size-sm={size === 'sm'} class:size-lg={size === 'lg'}>
    {#if $$slots.icon}
      <span class="input-icon">
        <slot name="icon" />
      </span>
    {/if}

    {#if type === 'textarea'}
      <textarea
        {name}
        {placeholder}
        {disabled}
        {readonly}
        {required}
        class="input-field"
        bind:value
        on:input={handleInput}
        on:change={handleChange}
        on:focus={handleFocus}
        on:blur={handleBlur}
        on:keydown={handleKeydown}
      ></textarea>
    {:else}
      <input
        {type}
        {name}
        {placeholder}
        {disabled}
        {readonly}
        {required}
        {autocomplete}
        {min}
        {max}
        {step}
        class="input-field"
        bind:value
        on:input={handleInput}
        on:change={handleChange}
        on:focus={handleFocus}
        on:blur={handleBlur}
        on:keydown={handleKeydown}
      />
    {/if}

    {#if $$slots.suffix}
      <span class="input-suffix">
        <slot name="suffix" />
      </span>
    {/if}
  </div>

  {#if error}
    <span class="input-error">{error}</span>
  {:else if helper}
    <span class="input-helper">{helper}</span>
  {/if}
</div>

<style>
  .input-wrapper {
    display: flex;
    flex-direction: column;
    gap: var(--space-1, 4px);
  }

  .input-wrapper.full-width {
    width: 100%;
  }

  .input-label {
    font-size: var(--text-sm, 12px);
    font-weight: 500;
    color: var(--text-secondary, #8b949e);
  }

  .input-label.required::after {
    content: ' *';
    color: var(--color-error, #f85149);
  }

  .input-container {
    display: flex;
    align-items: center;
    gap: var(--space-2, 8px);
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-md, 6px);
    padding: 0 var(--space-3, 12px);
    transition: var(--transition-fast, all 0.15s ease);
  }

  .input-container:focus-within {
    border-color: var(--color-primary, #58a6ff);
    box-shadow: 0 0 0 2px var(--color-primary-bg, rgba(88, 166, 255, 0.15));
  }

  .input-container.has-error {
    border-color: var(--color-error, #f85149);
  }

  .input-container.has-error:focus-within {
    box-shadow: 0 0 0 2px var(--color-error-bg, rgba(248, 81, 73, 0.15));
  }

  .input-container.disabled {
    opacity: 0.5;
    cursor: not-allowed;
    background: var(--bg-secondary, #161b22);
  }

  /* Sizes */
  .input-container {
    height: 36px;
  }

  .input-container.size-sm {
    height: 28px;
    padding: 0 var(--space-2, 8px);
  }

  .input-container.size-lg {
    height: 44px;
  }

  .input-field {
    flex: 1;
    min-width: 0;
    background: transparent;
    border: none;
    outline: none;
    font-size: var(--text-base, 13px);
    color: var(--text-primary, #c9d1d9);
    font-family: inherit;
  }

  .input-field::placeholder {
    color: var(--text-muted, #6e7681);
  }

  .input-field:disabled {
    cursor: not-allowed;
  }

  textarea.input-field {
    resize: vertical;
    min-height: 80px;
    padding: var(--space-2, 8px) 0;
  }

  .input-container:has(textarea) {
    height: auto;
    align-items: flex-start;
  }

  .input-icon {
    display: flex;
    align-items: center;
    color: var(--text-muted, #6e7681);
    flex-shrink: 0;
  }

  .input-icon :global(svg) {
    width: 16px;
    height: 16px;
  }

  .input-suffix {
    display: flex;
    align-items: center;
    color: var(--text-muted, #6e7681);
    flex-shrink: 0;
  }

  .input-error {
    font-size: var(--text-xs, 11px);
    color: var(--color-error, #f85149);
  }

  .input-helper {
    font-size: var(--text-xs, 11px);
    color: var(--text-muted, #6e7681);
  }

  /* Number input arrows */
  .input-field[type='number']::-webkit-outer-spin-button,
  .input-field[type='number']::-webkit-inner-spin-button {
    -webkit-appearance: none;
    margin: 0;
  }

  .input-field[type='number'] {
    -moz-appearance: textfield;
  }
</style>
