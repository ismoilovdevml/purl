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
    <span slot="description">Purl has not received a single log line.</span>
    <svelte:fragment slot="actions">
      <a href="#settings">Set up a source</a>
    </svelte:fragment>
  </EmptyState>

  Slots:
    default      — the description line (plain text is the common case)
    description  — same as default, for call sites that also fill `actions`
    actions      — buttons/links below the description
    extra        — full-width block under the actions (e.g. a code snippet)

  `title` is rendered as a <p>, not a heading: an empty state is a status
  message inside an existing region, so it must not inject a heading level into
  the document outline. Screen readers get it through role="status" instead.
-->
<script>
  import Icon from './Icon.svelte';

  /** Glyph imported from ./icons.js. */
  export let icon = null;
  /** The one-line summary. Say what is missing, not what the user did wrong. */
  export let title;
  /** 'sm' (inline panels) | 'md' (default) | 'lg' (full-page). */
  export let size = 'md';
  /** 'muted' (default) | 'accent' | 'error' — tints the icon only. */
  export let tone = 'muted';

  let className = '';
  export { className as class };

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
    <slot name="description"><slot /></slot>
  </div>

  {#if $$slots.actions}
    <div class="empty-actions">
      <slot name="actions" />
    </div>
  {/if}

  {#if $$slots.extra}
    <div class="empty-extra">
      <slot name="extra" />
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
    color: var(--text-secondary, #8b949e);
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
    color: var(--border-color, #30363d);
  }

  .tone-accent .empty-icon {
    color: var(--color-primary, #58a6ff);
  }

  .tone-error .empty-icon {
    color: var(--color-error, #f85149);
  }

  /* An all-clear ("All pods healthy") is a status, not an absence. Without
     this it renders in the muted border colour and reads as "nothing here",
     which is the opposite of what a green check is telling the operator. */
  .tone-success .empty-icon {
    color: var(--color-success, #3fb950);
  }

  .tone-success .empty-title {
    color: var(--color-success, #3fb950);
  }

  .empty-title {
    font-weight: 500;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  .sm .empty-title {
    font-size: var(--text-base, 13px);
  }

  .md .empty-title {
    font-size: var(--text-lg, 16px);
  }

  .lg .empty-title {
    font-size: var(--text-xl, 18px);
  }

  .empty-description {
    font-size: var(--text-base, 13px);
    color: var(--text-muted, #848d97);
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
