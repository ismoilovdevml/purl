<!--
  Button Component
  Reusable button with multiple variants and sizes

  Usage:
  <Button>Default</Button>
  <Button variant="primary">Primary</Button>
  <Button variant="danger" size="sm">Delete</Button>
  <Button icon><svg>...</svg></Button>
  <Button loading>Saving...</Button>
-->
<script>
  import { createEventDispatcher } from 'svelte';

  /** @type {'default' | 'primary' | 'success' | 'danger' | 'ghost' | 'link'} */
  export let variant = 'default';

  /** @type {'sm' | 'md' | 'lg'} */
  export let size = 'md';

  /** Button type attribute */
  export let type = 'button';

  /** Whether button only contains an icon */
  export let icon = false;

  /** Disabled state */
  export let disabled = false;

  /** Loading state */
  export let loading = false;

  /** Full width button */
  export let fullWidth = false;

  /** Additional CSS class */
  let className = '';
  export { className as class };

  const dispatch = createEventDispatcher();

  function handleClick(event) {
    if (!disabled && !loading) {
      dispatch('click', event);
    }
  }
</script>

<button
  {type}
  class="btn btn-{variant} btn-{size} {className}"
  class:btn-icon={icon}
  class:btn-loading={loading}
  class:btn-full={fullWidth}
  class:disabled={disabled || loading}
  disabled={disabled || loading}
  on:click={handleClick}
  on:mouseenter
  on:mouseleave
  on:focus
  on:blur
  {...$$restProps}
>
  {#if loading}
    <span class="spinner"></span>
  {/if}
  <span class="btn-content" class:invisible={loading && !icon}>
    <slot />
  </span>
</button>

<style>
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: var(--space-2, 8px);
    font-family: inherit;
    font-weight: var(--font-medium, 500);
    border-radius: var(--border-radius, 6px);
    cursor: pointer;
    transition: var(--transition-base, all 0.15s ease);
    white-space: nowrap;
    text-decoration: none;
    position: relative;
  }

  .btn:focus-visible {
    outline: 2px solid var(--color-primary, #58a6ff);
    outline-offset: 2px;
  }

  /* Sizes */
  .btn-sm {
    padding: 4px 10px;
    font-size: var(--text-sm, 11px);
    height: 28px;
  }

  .btn-md {
    padding: 6px 14px;
    font-size: var(--text-base, 13px);
    height: 34px;
  }

  .btn-lg {
    padding: 8px 18px;
    font-size: var(--text-md, 14px);
    height: 40px;
  }

  /* Icon-only buttons */
  .btn-icon.btn-sm {
    width: 28px;
    padding: 0;
  }

  .btn-icon.btn-md {
    width: 34px;
    padding: 0;
  }

  .btn-icon.btn-lg {
    width: 40px;
    padding: 0;
  }

  /* Variants */
  .btn-default {
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    color: var(--text-primary, #c9d1d9);
  }

  .btn-default:hover:not(.disabled) {
    background: var(--bg-hover, #30363d);
    border-color: var(--text-secondary, #8b949e);
  }

  .btn-primary {
    background: var(--color-primary, #58a6ff);
    border: 1px solid var(--color-primary, #58a6ff);
    color: #ffffff;
  }

  .btn-primary:hover:not(.disabled) {
    background: var(--color-primary-hover, #79b8ff);
    border-color: var(--color-primary-hover, #79b8ff);
  }

  .btn-success {
    background: var(--color-success, #238636);
    border: 1px solid var(--color-success, #238636);
    color: #ffffff;
  }

  .btn-success:hover:not(.disabled) {
    background: var(--color-success-hover, #2ea043);
    border-color: var(--color-success-hover, #2ea043);
  }

  .btn-danger {
    background: var(--color-error, #da3633);
    border: 1px solid var(--color-error, #da3633);
    color: #ffffff;
  }

  .btn-danger:hover:not(.disabled) {
    background: var(--color-error-hover, #f85149);
    border-color: var(--color-error-hover, #f85149);
  }

  .btn-ghost {
    background: transparent;
    border: 1px solid transparent;
    color: var(--text-secondary, #8b949e);
  }

  .btn-ghost:hover:not(.disabled) {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .btn-link {
    background: transparent;
    border: none;
    color: var(--color-primary, #58a6ff);
    padding: 0;
    height: auto;
    font-weight: normal;
  }

  .btn-link:hover:not(.disabled) {
    text-decoration: underline;
  }

  /* States */
  .disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn-full {
    width: 100%;
  }

  /* Loading */
  .btn-loading {
    cursor: wait;
  }

  .spinner {
    position: absolute;
    width: 14px;
    height: 14px;
    border: 2px solid transparent;
    border-top-color: currentColor;
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
  }

  .invisible {
    visibility: hidden;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .btn-content {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2, 8px);
  }

  /* SVG icons */
  .btn :global(svg) {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
  }

  .btn-sm :global(svg) {
    width: 14px;
    height: 14px;
  }

  .btn-lg :global(svg) {
    width: 18px;
    height: 18px;
  }
</style>
