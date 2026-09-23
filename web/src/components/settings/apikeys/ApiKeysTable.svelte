<!--
  ApiKeysTable
  Name / Key / Created / Status table of ingest API keys with a per-row
  Revoke button, and the empty state when there are none.
-->
<script>
  import Button from '../../ui/Button.svelte';
  import Icon from '../../ui/Icon.svelte';
  import EmptyState from '../../ui/EmptyState.svelte';
  import { key as keyIcon } from '../../ui/icons.js';

  let {
    /** API keys from GET /settings/api-keys */
    keys = [],
    /** Show the Revoke buttons (admin, keys not pinned by env) */
    canRevoke = false,
    /** (key) => void */
    onrevoke,
  } = $props();

  function formatKeyPrefix(key) {
    if (!key) return '';
    return key.substring(0, 8) + '...';
  }

  function formatDate(dateStr) {
    if (!dateStr) return '';
    try {
      const date = new Date(dateStr);
      return date.toLocaleDateString('en-US', {
        year: 'numeric',
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
      });
    } catch {
      return dateStr;
    }
  }
</script>

<div class="keys-table">
  <div class="table-header">
    <span class="col-name">Name</span>
    <span class="col-key">Key</span>
    <span class="col-created">Created</span>
    <span class="col-status">Status</span>
    <span class="col-actions"></span>
  </div>

  <div class="keys-list">
    {#each keys as key}
      <div class="key-row">
        <div class="col-name">
          <Icon icon={keyIcon} size={16} />
          <span class="key-name">{key.label || key.id}</span>
        </div>
        <div class="col-key">
          <code class="key-prefix">{key.masked_key || formatKeyPrefix(key.id)}</code>
        </div>
        <div class="col-created">
          <span class="key-date">{formatDate(key.created_at)}</span>
        </div>
        <div class="col-status">
          <span class="status-badge status-active">Active</span>
        </div>
        <div class="col-actions">
          {#if canRevoke}
            <Button variant="ghost" size="sm" onclick={() => onrevoke(key)}>
              Revoke
            </Button>
          {/if}
        </div>
      </div>
    {/each}

    {#if keys.length === 0}
      <EmptyState icon={keyIcon} title="No API keys configured" size="sm">
        Create one to start ingesting logs.
      </EmptyState>
    {/if}
  </div>
</div>

<style>
  .keys-table {
    display: flex;
    flex-direction: column;
  }

  .table-header {
    display: grid;
    grid-template-columns: 1fr 120px 150px 80px auto;
    padding: 6px 0;
    border-bottom: 1px solid var(--border-color);
    margin-bottom: 4px;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .keys-list {
    display: flex;
    flex-direction: column;
  }

  .key-row {
    display: grid;
    grid-template-columns: 1fr 120px 150px 80px auto;
    align-items: center;
    padding: 10px 0;
    border-bottom: 1px solid var(--border-muted);
  }

  .key-row:last-child {
    border-bottom: none;
  }

  .col-name {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .col-name :global(svg) {
    color: var(--text-muted);
    flex-shrink: 0;
  }

  .key-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-key {
    display: flex;
    align-items: center;
  }

  .key-prefix {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--text-secondary);
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 4px;
  }

  .col-created {
    display: flex;
    align-items: center;
  }

  .key-date {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .col-status {
    display: flex;
    align-items: center;
  }

  .status-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: 9999px;
    font-size: 0.6875rem;
    font-weight: 600;
    letter-spacing: 0.02em;
  }

  .status-active {
    background: rgba(63, 185, 80, 0.15);
    color: #3fb950;
  }

  .col-actions {
    display: flex;
    gap: 4px;
    justify-content: flex-end;
  }
</style>
