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
    gap: var(--space-1, 4px);
    padding: 2px 8px;
    font-size: var(--text-xs, 11px);
    font-weight: 500;
    line-height: 1.4;
    border-radius: var(--radius-sm, 4px);
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
    font-size: var(--text-sm, 12px);
  }

  .badge.pill {
    border-radius: 9999px;
  }

  /* Variants - Filled */
  .badge.variant-default {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-secondary, #8b949e);
  }

  .badge.variant-primary {
    background: var(--color-primary-bg, rgba(88, 166, 255, 0.15));
    color: var(--color-primary, #58a6ff);
  }

  .badge.variant-success {
    background: var(--color-success-bg, rgba(63, 185, 80, 0.15));
    color: var(--color-success, #3fb950);
  }

  .badge.variant-warning {
    background: var(--color-warning-bg, rgba(210, 153, 34, 0.15));
    color: var(--color-warning, #d29922);
  }

  .badge.variant-error {
    background: var(--color-error-bg, rgba(248, 81, 73, 0.15));
    color: var(--color-error, #f85149);
  }

  .badge.variant-info {
    background: var(--color-purple-bg, rgba(163, 113, 247, 0.15));
    color: var(--color-purple, #a371f7);
  }

  /* Outline variants */
  .badge.outline {
    background: transparent;
    border: 1px solid currentColor;
  }

  .badge.outline.variant-default {
    border-color: var(--border-color, #30363d);
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
