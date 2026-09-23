<!--
  Button Component
  Reusable button with multiple variants and sizes

  Usage:
  <Button>Default</Button>
  <Button variant="primary">Primary</Button>
  <Button variant="danger" size="sm">Delete</Button>
  <Button icon aria-label="Delete" onclick={remove}><Icon icon={trash} /></Button>
  <Button loading>Saving...</Button>
-->
<script>
  // Rest props are the point of this primitive (aria-*, title, on* handlers
  // pass straight through to <button>); it is never built as a custom element.
  // svelte-ignore custom_element_props_identifier
  let {
    /** @type {'default' | 'primary' | 'success' | 'danger' | 'ghost' | 'link'} */
    variant = 'default',
    /** @type {'sm' | 'md' | 'lg'} */
    size = 'md',
    /** Button type attribute */
    type = 'button',
    /** Whether button only contains an icon */
    icon = false,
    /** Disabled state */
    disabled = false,
    /** Loading state */
    loading = false,
    /** Full width button */
    fullWidth = false,
    /** Additional CSS class */
    class: className = '',
    /** Click callback — receives the native MouseEvent; suppressed while disabled/loading */
    onclick,
    children,
    /* Everything else (aria-*, title, onmouseenter, onfocus, ...) lands on <button>. */
    ...rest
  } = $props();

  function handleClick(event) {
    if (!disabled && !loading) {
      onclick?.(event);
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
  {...rest}
  onclick={handleClick}
>
  {#if loading}
    <span class="spinner"></span>
  {/if}
  <span class="btn-content" class:invisible={loading && !icon}>
    {@render children?.()}
  </span>
</button>

<style>
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: var(--space-2);
    font-family: inherit;
    font-weight: var(--font-medium);
    border-radius: var(--radius-md);
    cursor: pointer;
    transition: var(--transition-base);
    white-space: nowrap;
    text-decoration: none;
    position: relative;
  }

  .btn:focus-visible {
    outline: 2px solid var(--color-primary);
    outline-offset: 2px;
  }

  /* Sizes */
  .btn-sm {
    padding: 4px 10px;
    font-size: var(--text-xs);
    height: 28px;
  }

  .btn-md {
    padding: 6px 14px;
    font-size: var(--text-base);
    height: 34px;
  }

  .btn-lg {
    padding: 8px 18px;
    font-size: var(--text-md);
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
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    color: var(--text-primary);
  }

  .btn-default:hover:not(.disabled) {
    background: var(--bg-hover);
    border-color: var(--text-secondary);
  }

  .btn-primary {
    background: var(--color-primary);
    border: 1px solid var(--color-primary);
    color: #ffffff;
  }

  .btn-primary:hover:not(.disabled) {
    background: var(--color-primary-hover);
    border-color: var(--color-primary-hover);
  }

  .btn-success {
    background: var(--color-success-solid);
    border: 1px solid var(--color-success-solid);
    color: #ffffff;
  }

  .btn-success:hover:not(.disabled) {
    background: var(--color-success-solid-hover);
    border-color: var(--color-success-solid-hover);
  }

  .btn-danger {
    background: var(--color-error-solid);
    border: 1px solid var(--color-error-solid);
    color: #ffffff;
  }

  .btn-danger:hover:not(.disabled) {
    background: var(--color-error-solid-hover);
    border-color: var(--color-error-solid-hover);
  }

  .btn-ghost {
    background: transparent;
    border: 1px solid transparent;
    color: var(--text-secondary);
  }

  .btn-ghost:hover:not(.disabled) {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .btn-link {
    background: transparent;
    border: none;
    color: var(--color-primary);
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
    /* @keyframes spin is declared globally in src/styles/animations.css. */
    animation: spin 0.6s linear infinite;
  }

  .invisible {
    visibility: hidden;
  }

  .btn-content {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
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
