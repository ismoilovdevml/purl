<!--
  Card Component
  Container with optional header and footer

  Usage:
  <Card title="Settings">
    Content here
  </Card>

  <Card>
    <svelte:fragment slot="header">Custom Header</svelte:fragment>
    Content
    <svelte:fragment slot="footer">Footer</svelte:fragment>
  </Card>
-->
<script>
  /** Card title */
  export let title = '';

  /** Card subtitle */
  export let subtitle = '';

  /** Padding size */
  export let padding = 'md'; // none, sm, md, lg

  /** No background (transparent) */
  export let transparent = false;

  /** Hover effect */
  export let hoverable = false;

  /** Clickable (adds cursor) */
  export let clickable = false;

  /** Bordered style */
  export let bordered = true;
</script>

<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div
  class="card"
  class:transparent
  class:hoverable
  class:clickable
  class:bordered
  class:padding-none={padding === 'none'}
  class:padding-sm={padding === 'sm'}
  class:padding-lg={padding === 'lg'}
  on:click
  on:keydown
  role={clickable ? 'button' : undefined}
  tabindex={clickable ? 0 : -1}
>
  {#if title || subtitle || $$slots.header}
    <div class="card-header">
      {#if $$slots.header}
        <slot name="header" />
      {:else}
        <div class="card-titles">
          {#if title}
            <h3 class="card-title">{title}</h3>
          {/if}
          {#if subtitle}
            <p class="card-subtitle">{subtitle}</p>
          {/if}
        </div>
      {/if}
      {#if $$slots.actions}
        <div class="card-actions">
          <slot name="actions" />
        </div>
      {/if}
    </div>
  {/if}

  <div class="card-body">
    <slot />
  </div>

  {#if $$slots.footer}
    <div class="card-footer">
      <slot name="footer" />
    </div>
  {/if}
</div>

<style>
  .card {
    background: var(--bg-secondary, #161b22);
    border-radius: var(--radius-lg, 8px);
    overflow: hidden;
  }

  .card.bordered {
    border: 1px solid var(--border-color, #30363d);
  }

  .card.transparent {
    background: transparent;
  }

  .card.hoverable {
    transition: var(--transition-fast, all 0.15s ease);
  }

  .card.hoverable:hover {
    border-color: var(--border-hover, #484f58);
    background: var(--bg-tertiary, #21262d);
  }

  .card.clickable {
    cursor: pointer;
  }

  .card.clickable:focus-visible {
    outline: 2px solid var(--color-primary, #58a6ff);
    outline-offset: 2px;
  }

  /* Header */
  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3, 12px);
    padding: var(--space-4, 16px);
    border-bottom: 1px solid var(--border-color, #30363d);
  }

  .card-titles {
    flex: 1;
    min-width: 0;
  }

  .card-title {
    margin: 0;
    font-size: var(--text-base, 14px);
    font-weight: 600;
    color: var(--text-primary, #c9d1d9);
  }

  .card-subtitle {
    margin: var(--space-1, 4px) 0 0;
    font-size: var(--text-sm, 12px);
    color: var(--text-secondary, #8b949e);
  }

  .card-actions {
    display: flex;
    align-items: center;
    gap: var(--space-2, 8px);
    flex-shrink: 0;
  }

  /* Body */
  .card-body {
    padding: var(--space-4, 16px);
  }

  .card.padding-none .card-body {
    padding: 0;
  }

  .card.padding-sm .card-body {
    padding: var(--space-3, 12px);
  }

  .card.padding-lg .card-body {
    padding: var(--space-6, 24px);
  }

  /* Footer */
  .card-footer {
    padding: var(--space-3, 12px) var(--space-4, 16px);
    border-top: 1px solid var(--border-color, #30363d);
    background: var(--bg-tertiary, #21262d);
  }
</style>
