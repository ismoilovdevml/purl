<!--
  LoadingSpinner Component
  Animated loading indicator

  Usage:
  <LoadingSpinner />
  <LoadingSpinner size="lg" />
  <LoadingSpinner label="Loading logs..." />
-->
<script>
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
        <svg viewBox="0 0 24 24" fill="none">
          <circle cx="12" cy="12" r="10" stroke="currentColor" stroke-width="3" opacity="0.2" />
          <path
            d="M12 2a10 10 0 0110 10"
            stroke="currentColor"
            stroke-width="3"
            stroke-linecap="round"
          />
        </svg>
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
      <svg viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="10" stroke="currentColor" stroke-width="3" opacity="0.2" />
        <path
          d="M12 2a10 10 0 0110 10"
          stroke="currentColor"
          stroke-width="3"
          stroke-linecap="round"
        />
      </svg>
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
    color: var(--text-muted, #6e7681);
    animation: spin 1s linear infinite;
  }

  .spinner.variant-primary {
    color: var(--color-primary, #58a6ff);
  }

  .spinner svg {
    width: 24px;
    height: 24px;
  }

  /* Sizes */
  .spinner.size-xs svg {
    width: 14px;
    height: 14px;
  }

  .spinner.size-sm svg {
    width: 18px;
    height: 18px;
  }

  .spinner.size-lg svg {
    width: 32px;
    height: 32px;
  }

  .spinner.size-xl svg {
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

  @keyframes spin {
    from {
      transform: rotate(0deg);
    }
    to {
      transform: rotate(360deg);
    }
  }
</style>
