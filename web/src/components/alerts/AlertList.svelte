<!--
  AlertList
  The rows of the sidebar alerts panel: each alert's name and rule (click to
  edit), an enable/disable toggle and a delete button. Optimistic rows
  (`pending`) render dashed and have every action disabled until the server
  list confirms them. AlertsPanel owns the list and performs every action.
-->
<script>
  import Button from '../ui/Button.svelte';
  import Icon from '../ui/Icon.svelte';
  import { dot, dotOutline, close } from '../ui/icons.js';

  let {
    /** Alerts to render (server rows followed by pending ones) */
    alerts,
    /** (alert) => void — open the edit modal */
    onedit,
    /** (alert) => void — flip `enabled` */
    ontoggle,
    /** (id) => void — ask for delete confirmation */
    ondelete,
  } = $props();
</script>

<ul>
  {#each alerts as alert (alert.id)}
    <!-- A pending row is shown for feedback but carries a placeholder
         id, so every action that needs the real one stays disabled
         until the server list confirms it. -->
    <li class:disabled={!alert.enabled} class:pending={alert.pending}>
      <button class="alert-info" onclick={() => onedit(alert)} disabled={alert.pending}>
        <span class="name">{alert.name}</span>
        <span class="details">
          {alert.query || 'All logs'} >= {alert.threshold} in {alert.window_minutes}m
        </span>
      </button>
      <Button
        icon
        size="sm"
        variant="ghost"
        onclick={() => ontoggle(alert)}
        title={alert.enabled ? 'Disable' : 'Enable'}
        aria-label="{alert.enabled ? 'Disable' : 'Enable'} alert {alert.name}"
        disabled={alert.pending}
      >
        {#if alert.enabled}
          <Icon icon={dot} size={14} color="#3fb950" />
        {:else}
          <Icon icon={dotOutline} size={14} strokeWidth={2.5} color="#848d97" />
        {/if}
      </Button>
      <Button
        icon
        size="sm"
        variant="ghost"
        onclick={() => ondelete(alert.id)}
        title="Delete alert"
        aria-label="Delete alert {alert.name}"
        class="delete-btn"
        disabled={alert.pending}
      >
        <Icon icon={close} size={12} strokeWidth={3} />
      </Button>
    </li>
  {/each}
</ul>

<style>
  ul {
    list-style: none;
  }

  li {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-bottom: 4px;
  }

  li.disabled {
    opacity: 0.5;
  }

  /* Optimistic row: visible immediately, but visibly not settled yet. */
  li.pending .alert-info {
    border-style: dashed;
    border-color: var(--color-primary);
    cursor: default;
  }

  li.pending {
    opacity: 0.7;
  }

  .alert-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    padding: 8px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    cursor: pointer;
    text-align: left;
  }

  .alert-info:hover {
    border-color: var(--color-primary);
  }

  .name {
    color: var(--text-primary);
    font-size: 13px;
    font-weight: 500;
  }

  .details {
    color: var(--text-secondary);
    font-size: 11px;
  }

  :global(.delete-btn):hover {
    color: var(--color-error) !important;
  }
</style>
