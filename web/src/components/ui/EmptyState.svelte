<!--
  EmptyState

  The one place that renders "there is nothing here". Every list, table and
  panel in the app had grown its own centred-icon-plus-two-lines block; this
  replaces them so the wording hierarchy, icon weight and spacing stay
  identical everywhere.

  Usage:
  <EmptyState icon={search} title="No logs match this search">
    Try widening the time range or removing a filter.
  </EmptyState>

  <EmptyState icon={box} title="No logs yet" size="lg" tone="accent">
    {#snippet description()}Purl has not received a single log line.{/snippet}
    {#snippet actions()}
      <a href="#settings">Set up a source</a>
    {/snippet}
  </EmptyState>

  Snippets:
    children     — the description line (plain text is the common case)
    description  — same as children, for call sites that also fill `actions`
    actions      — buttons/links below the description
    extra        — full-width block under the actions (e.g. a code snippet)

  `title` is rendered as a <p>, not a heading: an empty state is a status
  message inside an existing region, so it must not inject a heading level into
  the document outline. Screen readers get it through role="status" instead.
-->
<script>
  import Icon from './Icon.svelte';

  let {
    /** Glyph imported from ./icons.js. */
    icon = null,
    /** The one-line summary. Say what is missing, not what the user did wrong. */
    title,
    /** 'sm' (inline panels) | 'md' (default) | 'lg' (full-page). */
    size = 'md',
    /** 'muted' (default) | 'accent' | 'error' — tints the icon only. */
    tone = 'muted',
    class: className = '',
    /** Description line; `children` is the same thing for the plain-text case. */
    description,
    /** Buttons/links below the description. */
    actions,
    /** Full-width block under the actions (e.g. a code snippet). */
    extra,
    children,
  } = $props();

  const ICON_SIZE = { sm: 24, md: 40, lg: 56 };
</script>

<div class="empty-state {size} tone-{tone} {className}" role="status">
  {#if icon}
    <div class="empty-icon">
      <Icon {icon} size={ICON_SIZE[size] ?? ICON_SIZE.md} strokeWidth={1.5} />
    </div>
  {/if}

  <p class="empty-title">{title}</p>

  <div class="empty-description">
    {#if description}
      {@render description()}
    {:else}
      {@render children?.()}
    {/if}
  </div>

  {#if actions}
    <div class="empty-actions">
      {@render actions()}
    </div>
  {/if}

  {#if extra}
    <div class="empty-extra">
      {@render extra()}
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
    color: var(--text-secondary);
  }

  .empty-state.sm {
    padding: 20px 16px;
    gap: 6px;
  }

  .empty-state.md {
    padding: 60px 20px;
    gap: 8px;
  }

  .empty-state.lg {
    padding: 80px 24px;
    gap: 10px;
  }

  .empty-icon {
    display: flex;
    margin-bottom: 8px;
    color: var(--border-color);
  }

  .tone-accent .empty-icon {
    color: var(--color-primary);
  }

  .tone-error .empty-icon {
    color: var(--color-error);
  }

  /* An all-clear ("All pods healthy") is a status, not an absence. Without
     this it renders in the muted border colour and reads as "nothing here",
     which is the opposite of what a green check is telling the operator. */
  .tone-success .empty-icon {
    color: var(--color-success);
  }

  .tone-success .empty-title {
    color: var(--color-success);
  }

  .empty-title {
    font-weight: 500;
    color: var(--text-secondary);
    margin: 0;
  }

  .sm .empty-title {
    font-size: var(--text-base);
  }

  .md .empty-title {
    font-size: var(--text-lg);
  }

  .lg .empty-title {
    font-size: var(--text-xl);
  }

  .empty-description {
    font-size: var(--text-base);
    color: var(--text-muted);
    max-width: 46ch;
    line-height: 1.5;
  }

  /* Collapse the row entirely when the slot renders nothing. */
  .empty-description:empty {
    display: none;
  }

  .empty-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: center;
    gap: 8px;
    margin-top: 8px;
  }

  .empty-extra {
    width: 100%;
    max-width: 560px;
    margin-top: 16px;
    text-align: left;
  }
</style>
