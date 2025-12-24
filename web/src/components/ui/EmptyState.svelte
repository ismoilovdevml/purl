<!--
  EmptyState Component
  Placeholder for empty lists and search results

  Usage:
  <EmptyState
    title="No logs found"
    description="Try adjusting your search filters"
    icon="search"
  />
-->
<script>
  /** Title text */
  export let title = 'No data';

  /** Description text */
  export let description = '';

  /** Size variant */
  export let size = 'md'; // sm, md, lg

  /** Compact mode (inline) */
  export let compact = false;
</script>

<div
  class="empty-state"
  class:compact
  class:size-sm={size === 'sm'}
  class:size-lg={size === 'lg'}
>
  {#if $$slots.icon}
    <div class="empty-icon">
      <slot name="icon" />
    </div>
  {:else}
    <div class="empty-icon default-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
        <path d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z" />
      </svg>
    </div>
  {/if}

  <div class="empty-content">
    <h4 class="empty-title">{title}</h4>
    {#if description}
      <p class="empty-description">{description}</p>
    {/if}
  </div>

  {#if $$slots.action}
    <div class="empty-action">
      <slot name="action" />
    </div>
  {/if}
</div>

<style>
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
    padding: var(--space-8, 48px) var(--space-4, 16px);
    gap: var(--space-4, 16px);
  }

  .empty-state.compact {
    flex-direction: row;
    padding: var(--space-4, 16px);
    gap: var(--space-3, 12px);
    text-align: left;
  }

  /* Sizes */
  .empty-state.size-sm {
    padding: var(--space-4, 16px);
    gap: var(--space-2, 8px);
  }

  .empty-state.size-lg {
    padding: var(--space-12, 64px) var(--space-4, 16px);
    gap: var(--space-6, 24px);
  }

  /* Icon */
  .empty-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-muted, #6e7681);
  }

  .empty-icon :global(svg) {
    width: 48px;
    height: 48px;
  }

  .empty-state.size-sm .empty-icon :global(svg) {
    width: 32px;
    height: 32px;
  }

  .empty-state.size-lg .empty-icon :global(svg) {
    width: 64px;
    height: 64px;
  }

  .empty-state.compact .empty-icon :global(svg) {
    width: 24px;
    height: 24px;
  }

  .default-icon {
    padding: var(--space-4, 16px);
    background: var(--bg-tertiary, #21262d);
    border-radius: 50%;
  }

  .empty-state.size-sm .default-icon {
    padding: var(--space-2, 8px);
  }

  .empty-state.compact .default-icon {
    padding: var(--space-2, 8px);
  }

  /* Content */
  .empty-content {
    display: flex;
    flex-direction: column;
    gap: var(--space-1, 4px);
  }

  .empty-title {
    margin: 0;
    font-size: var(--text-base, 14px);
    font-weight: 500;
    color: var(--text-secondary, #8b949e);
  }

  .empty-state.size-sm .empty-title {
    font-size: var(--text-sm, 12px);
  }

  .empty-state.size-lg .empty-title {
    font-size: var(--text-lg, 16px);
  }

  .empty-description {
    margin: 0;
    font-size: var(--text-sm, 12px);
    color: var(--text-muted, #6e7681);
    max-width: 300px;
  }

  .empty-state.size-lg .empty-description {
    font-size: var(--text-base, 14px);
    max-width: 400px;
  }

  /* Action */
  .empty-action {
    margin-top: var(--space-2, 8px);
  }

  .empty-state.compact .empty-action {
    margin-top: 0;
    margin-left: auto;
  }
</style>
