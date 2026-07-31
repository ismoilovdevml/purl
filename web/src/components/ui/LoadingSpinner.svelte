<!--
  LoadingSpinner Component
  Animated loading indicator

  Usage:
  <LoadingSpinner />
  <LoadingSpinner size="lg" />
  <LoadingSpinner label="Loading logs..." />
-->
<script>
  import Icon from './Icon.svelte';
  import { spinner } from './icons.js';

  /** Size */
  export let size = 'md'; // xs, sm, md, lg, xl

  /** Loading text */
  export let label = '';

  /** Center in parent */
  export let centered = false;

  /** Overlay mode */
  export let overlay = false;

  /** Color variant */
  export let variant = 'default'; // default, primary
</script>

{#if overlay}
  <div class="spinner-overlay">
    <div class="spinner-container" class:centered>
      <div
        class="spinner"
        class:size-xs={size === 'xs'}
        class:size-sm={size === 'sm'}
        class:size-lg={size === 'lg'}
        class:size-xl={size === 'xl'}
        class:variant-primary={variant === 'primary'}
        role="status"
        aria-label={label || 'Loading'}
      >
        <Icon icon={spinner} />
      </div>
      {#if label}
        <span class="spinner-label">{label}</span>
      {/if}
    </div>
  </div>
{:else}
  <div class="spinner-container" class:centered>
    <div
      class="spinner"
      class:size-xs={size === 'xs'}
      class:size-sm={size === 'sm'}
      class:size-lg={size === 'lg'}
      class:size-xl={size === 'xl'}
      class:variant-primary={variant === 'primary'}
      role="status"
      aria-label={label || 'Loading'}
    >
      <Icon icon={spinner} />
    </div>
    {#if label}
      <span class="spinner-label">{label}</span>
    {/if}
  </div>
{/if}

<style>
  .spinner-container {
    display: inline-flex;
    align-items: center;
    gap: var(--space-2, 8px);
  }

  .spinner-container.centered {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    width: 100%;
    padding: var(--space-8, 48px);
  }

  .spinner-overlay {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--bg-overlay, rgba(13, 17, 23, 0.8));
    z-index: var(--z-overlay, 100);
  }

  .spinner {
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-muted, #848d97);
    animation: spin 1s linear infinite;
  }

  .spinner.variant-primary {
    color: var(--color-primary, #58a6ff);
  }

  .spinner :global(svg) {
    width: 24px;
    height: 24px;
  }

  /* Sizes */
  .spinner.size-xs :global(svg) {
    width: 14px;
    height: 14px;
  }

  .spinner.size-sm :global(svg) {
    width: 18px;
    height: 18px;
  }

  .spinner.size-lg :global(svg) {
    width: 32px;
    height: 32px;
  }

  .spinner.size-xl :global(svg) {
    width: 48px;
    height: 48px;
  }

  .spinner-label {
    font-size: var(--text-sm, 12px);
    color: var(--text-secondary, #8b949e);
  }

  .spinner-container.centered .spinner-label {
    margin-top: var(--space-2, 8px);
  }
</style>
