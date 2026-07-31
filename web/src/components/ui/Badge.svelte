<!--
  Badge Component
  Status indicators and count badges

  Usage:
  <Badge>Default</Badge>
  <Badge variant="success">Active</Badge>
  <Badge variant="error" dot>Error</Badge>
  <Badge count={42} />
-->
<script>
  /** Badge variant */
  export let variant = 'default'; // default, primary, success, warning, error, info

  /** Size */
  export let size = 'md'; // sm, md, lg

  /** Show dot indicator */
  export let dot = false;

  /** Count to display (overrides slot) */
  export let count = null;

  /** Max count before showing + */
  export let maxCount = 99;

  /** Pill shape (more rounded) */
  export let pill = false;

  /** Outline style */
  export let outline = false;

  $: displayCount = count !== null
    ? (count > maxCount ? `${maxCount}+` : count)
    : null;
</script>

<span
  class="badge"
  class:variant-default={variant === 'default'}
  class:variant-primary={variant === 'primary'}
  class:variant-success={variant === 'success'}
  class:variant-warning={variant === 'warning'}
  class:variant-error={variant === 'error'}
  class:variant-info={variant === 'info'}
  class:size-sm={size === 'sm'}
  class:size-lg={size === 'lg'}
  class:pill
  class:outline
  class:dot-only={dot && !$$slots.default && count === null}
>
  {#if dot}
    <span class="badge-dot"></span>
  {/if}
  {#if displayCount !== null}
    {displayCount}
  {:else}
    <slot />
  {/if}
</span>

<style>
  .badge {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
    padding: 2px 8px;
    font-size: var(--text-xs);
    font-weight: 500;
    line-height: 1.4;
    border-radius: var(--radius-sm);
    white-space: nowrap;
    user-select: none;
  }

  /* Sizes */
  .badge.size-sm {
    padding: 1px 6px;
    font-size: 10px;
  }

  .badge.size-lg {
    padding: 4px 12px;
    font-size: var(--text-sm);
  }

  .badge.pill {
    border-radius: 9999px;
  }

  /* Variants - Filled */
  .badge.variant-default {
    background: var(--bg-tertiary);
    color: var(--text-secondary);
  }

  .badge.variant-primary {
    background: var(--color-primary-bg);
    color: var(--color-primary);
  }

  .badge.variant-success {
    background: var(--color-success-bg);
    color: var(--color-success);
  }

  .badge.variant-warning {
    background: var(--color-warning-bg);
    color: var(--color-warning);
  }

  .badge.variant-error {
    background: var(--color-error-bg);
    color: var(--color-error);
  }

  .badge.variant-info {
    background: var(--color-purple-bg);
    color: var(--color-purple);
  }

  /* Outline variants */
  .badge.outline {
    background: transparent;
    border: 1px solid currentColor;
  }

  .badge.outline.variant-default {
    border-color: var(--border-color);
  }

  /* Dot */
  .badge-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: currentColor;
    flex-shrink: 0;
  }

  .badge.size-sm .badge-dot {
    width: 5px;
    height: 5px;
  }

  .badge.size-lg .badge-dot {
    width: 8px;
    height: 8px;
  }

  /* Dot only (no text) */
  .badge.dot-only {
    padding: 4px;
    border-radius: 50%;
  }

  .badge.dot-only .badge-dot {
    width: 8px;
    height: 8px;
  }
</style>
