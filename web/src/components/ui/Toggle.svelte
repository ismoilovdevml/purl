<!--
  Toggle Component
  Switch toggle for boolean values

  Usage:
  <Toggle bind:checked={enabled} label="Enable notifications" />
-->
<script>
  import { createEventDispatcher } from 'svelte';

  /** Checked state */
  export let checked = false;

  /** Label text */
  export let label = '';

  /** Description text */
  export let description = '';

  /** Disabled state */
  export let disabled = false;

  /** Size */
  export let size = 'md'; // sm, md

  /** Label position */
  export let labelPosition = 'right'; // left, right

  const dispatch = createEventDispatcher();

  function toggle() {
    if (disabled) return;
    checked = !checked;
    dispatch('change', { checked });
  }

  function handleKeydown(event) {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      toggle();
    }
  }
</script>

<div
  class="toggle-wrapper"
  class:disabled
  class:label-left={labelPosition === 'left'}
>
  {#if label && labelPosition === 'left'}
    <div class="toggle-content">
      <span class="toggle-label">{label}</span>
      {#if description}
        <span class="toggle-description">{description}</span>
      {/if}
    </div>
  {/if}

  <button
    type="button"
    class="toggle"
    class:checked
    class:size-sm={size === 'sm'}
    {disabled}
    role="switch"
    aria-checked={checked}
    aria-label={label || 'Toggle'}
    on:click={toggle}
    on:keydown={handleKeydown}
  >
    <span class="toggle-handle"></span>
  </button>

  {#if label && labelPosition === 'right'}
    <div class="toggle-content">
      <span class="toggle-label">{label}</span>
      {#if description}
        <span class="toggle-description">{description}</span>
      {/if}
    </div>
  {/if}
</div>

<style>
  .toggle-wrapper {
    display: inline-flex;
    align-items: flex-start;
    gap: var(--space-3, 12px);
    cursor: pointer;
  }

  .toggle-wrapper.disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .toggle-wrapper.label-left {
    flex-direction: row-reverse;
  }

  .toggle {
    position: relative;
    flex-shrink: 0;
    width: 44px;
    height: 24px;
    padding: 2px;
    background: var(--bg-hover, #30363d);
    border: none;
    border-radius: 12px;
    cursor: pointer;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .toggle:focus-visible {
    outline: 2px solid var(--color-primary, #58a6ff);
    outline-offset: 2px;
  }

  .toggle:disabled {
    cursor: not-allowed;
  }

  .toggle.checked {
    background: var(--color-primary, #58a6ff);
  }

  .toggle.size-sm {
    width: 36px;
    height: 20px;
  }

  .toggle-handle {
    display: block;
    width: 20px;
    height: 20px;
    background: white;
    border-radius: 50%;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
    transition: var(--transition-fast, all 0.15s ease);
  }

  .toggle.checked .toggle-handle {
    transform: translateX(20px);
  }

  .toggle.size-sm .toggle-handle {
    width: 16px;
    height: 16px;
  }

  .toggle.size-sm.checked .toggle-handle {
    transform: translateX(16px);
  }

  .toggle-content {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding-top: 2px;
  }

  .toggle-label {
    font-size: var(--text-base, 13px);
    font-weight: 500;
    color: var(--text-primary, #c9d1d9);
    line-height: 1.4;
  }

  .toggle-description {
    font-size: var(--text-sm, 12px);
    color: var(--text-secondary, #8b949e);
    line-height: 1.4;
  }
</style>
