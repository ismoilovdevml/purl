<!--
  Card Component
  Container with optional header and footer

  Usage:
  <Card title="Settings">
    Content here
  </Card>

  <Card>
    {#snippet header()}Custom Header{/snippet}
    Content
    {#snippet footer()}Footer{/snippet}
  </Card>
-->
<script>
  let {
    /** Card title */
    title = '',
    /** Card subtitle */
    subtitle = '',
    /** Padding size: none, sm, md, lg */
    padding = 'md',
    /** No background (transparent) */
    transparent = false,
    /** Hover effect */
    hoverable = false,
    /** Clickable (adds cursor) */
    clickable = false,
    /** Bordered style */
    bordered = true,
    /** Click callback (native MouseEvent) */
    onclick,
    /** Snippet replacing the title/subtitle block */
    header,
    /** Snippet rendered on the right of the header */
    actions,
    /** Snippet rendered below the body */
    footer,
    children,
  } = $props();

  function handleKeydown(event) {
    if (clickable && (event.key === 'Enter' || event.key === ' ')) {
      event.preventDefault();
      event.target.closest('.card')?.click();
    }
  }
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
  {onclick}
  onkeydown={handleKeydown}
  role={clickable ? 'button' : undefined}
  tabindex={clickable ? 0 : -1}
>
  {#if title || subtitle || header}
    <div class="card-header">
      {#if header}
        {@render header()}
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
      {#if actions}
        <div class="card-actions">
          {@render actions()}
        </div>
      {/if}
    </div>
  {/if}

  <div class="card-body">
    {@render children?.()}
  </div>

  {#if footer}
    <div class="card-footer">
      {@render footer()}
    </div>
  {/if}
</div>

<style>
  .card {
    background: var(--bg-secondary);
    border-radius: var(--radius-lg);
    overflow: hidden;
  }

  .card.bordered {
    border: 1px solid var(--border-color);
  }

  .card.transparent {
    background: transparent;
  }

  .card.hoverable {
    transition: var(--transition-fast);
  }

  .card.hoverable:hover {
    border-color: var(--border-hover);
    background: var(--bg-tertiary);
  }

  .card.clickable {
    cursor: pointer;
  }

  .card.clickable:focus-visible {
    outline: 2px solid var(--color-primary);
    outline-offset: 2px;
  }

  /* Header */
  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-4);
    border-bottom: 1px solid var(--border-color);
  }

  .card-titles {
    flex: 1;
    min-width: 0;
  }

  .card-title {
    margin: 0;
    font-size: var(--text-md);
    font-weight: 600;
    color: var(--text-primary);
  }

  .card-subtitle {
    margin: var(--space-1) 0 0;
    font-size: var(--text-sm);
    color: var(--text-secondary);
  }

  .card-actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    flex-shrink: 0;
  }

  /* Body */
  .card-body {
    padding: var(--space-4);
  }

  .card.padding-none .card-body {
    padding: 0;
  }

  .card.padding-sm .card-body {
    padding: var(--space-3);
  }

  .card.padding-lg .card-body {
    padding: var(--space-6);
  }

  /* Footer */
  .card-footer {
    padding: var(--space-3) var(--space-4);
    border-top: 1px solid var(--border-color);
    background: var(--bg-tertiary);
  }
</style>
