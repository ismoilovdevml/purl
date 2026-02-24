<!--
  ApiKeysSettings Component
  Manage API keys for log ingestion

  Usage:
  <ApiKeysSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import Input from '../ui/Input.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import ConfirmDialog from '../ui/ConfirmDialog.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';

  const API_BASE = '/api';

  let keys = [];
  let loading = true;
  let error = '';

  // Create key form
  let showCreateForm = false;
  let newKeyName = '';
  let creating = false;

  // Newly created key (shown once)
  let createdKey = null;
  let copied = false;

  // Revoke confirmation
  let showRevokeConfirm = false;
  let revokingKey = null;

  onMount(() => {
    fetchKeys();
  });

  async function fetchKeys() {
    loading = true;
    error = '';
    try {
      const res = await fetch(`${API_BASE}/settings/api-keys`);
      if (res.ok) {
        const data = await res.json();
        keys = data.keys || [];
      } else {
        const data = await res.json();
        error = data.error || 'Failed to load API keys';
      }
    } catch {
      error = 'Failed to load API keys';
    } finally {
      loading = false;
    }
  }

  async function handleCreateKey() {
    if (!newKeyName.trim()) return;
    creating = true;
    try {
      const res = await fetch(`${API_BASE}/settings/api-keys`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: newKeyName.trim() })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to create API key');
      createdKey = data.key;
      copied = false;
      toastSuccess(`API key "${newKeyName.trim()}" created`);
      newKeyName = '';
      showCreateForm = false;
      await fetchKeys();
    } catch (err) {
      toastError('Failed to create API key: ' + err.message);
    } finally {
      creating = false;
    }
  }

  function confirmRevoke(key) {
    revokingKey = key;
    showRevokeConfirm = true;
  }

  async function handleRevoke() {
    if (!revokingKey) return;
    try {
      const res = await fetch(`${API_BASE}/settings/api-keys/${revokingKey.id}`, {
        method: 'DELETE'
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to revoke API key');
      toastSuccess(`API key "${revokingKey.name}" revoked`);
      revokingKey = null;
      await fetchKeys();
    } catch (err) {
      toastError('Failed to revoke API key: ' + err.message);
    }
  }

  async function copyToClipboard(text) {
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
      toastSuccess('API key copied to clipboard');
      setTimeout(() => { copied = false; }, 3000);
    } catch {
      toastError('Failed to copy to clipboard');
    }
  }

  function dismissCreatedKey() {
    createdKey = null;
    copied = false;
  }

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

<section class="settings-section">
  <div class="section-header">
    <h3>API Keys</h3>
    <p>Manage API keys for log ingestion</p>
  </div>

  {#if loading}
    <Card padding="lg">
      <LoadingSpinner centered label="Loading API keys..." />
    </Card>
  {:else}
    {#if error}
      <div class="error-msg">{error}</div>
    {/if}

    {#if createdKey}
      <div class="created-key-banner">
        <div class="created-key-header">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
          </svg>
          <strong>New API Key Created</strong>
        </div>
        <p class="created-key-warning">
          Copy this key now. You will not be able to see it again.
        </p>
        <div class="created-key-value">
          <code>{createdKey.key}</code>
          <button class="copy-btn" on:click={() => copyToClipboard(createdKey.key)} title="Copy to clipboard">
            {#if copied}
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <polyline points="20 6 9 17 4 12"/>
              </svg>
            {:else}
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
              </svg>
            {/if}
          </button>
        </div>
        <Button variant="ghost" size="sm" on:click={dismissCreatedKey}>Dismiss</Button>
      </div>
    {/if}

    <Card padding="md">
      <div class="keys-header">
        <span class="key-count">
          {keys.length} key{keys.length !== 1 ? 's' : ''}
        </span>
        <Button variant="primary" size="sm" on:click={() => { showCreateForm = !showCreateForm; }}>
          {showCreateForm ? 'Cancel' : 'Create Key'}
        </Button>
      </div>

      {#if showCreateForm}
        <div class="create-form">
          <Input
            bind:value={newKeyName}
            placeholder="Key name (e.g. production-ingest)"
            label="Key Name"
            fullWidth
            on:enter={handleCreateKey}
          />
          <Button
            variant="success"
            size="sm"
            on:click={handleCreateKey}
            loading={creating}
            disabled={!newKeyName.trim()}
          >
            Create
          </Button>
        </div>
      {/if}

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
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>
                </svg>
                <span class="key-name">{key.name}</span>
              </div>
              <div class="col-key">
                <code class="key-prefix">{formatKeyPrefix(key.key || key.prefix || key.id)}</code>
              </div>
              <div class="col-created">
                <span class="key-date">{formatDate(key.created_at)}</span>
              </div>
              <div class="col-status">
                <span class="status-badge status-active">Active</span>
              </div>
              <div class="col-actions">
                <Button variant="ghost" size="sm" on:click={() => confirmRevoke(key)}>
                  Revoke
                </Button>
              </div>
            </div>
          {/each}

          {#if keys.length === 0}
            <div class="empty">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>
              </svg>
              <p>No API keys configured. Create one to start ingesting logs.</p>
            </div>
          {/if}
        </div>
      </div>
    </Card>

    <Card padding="md">
      <h4 class="info-title">Usage</h4>
      <p class="info-text">
        Include the API key in your log ingestion requests using the <code>X-API-Key</code> header
        or the <code>Authorization: Bearer</code> header.
      </p>
      <div class="usage-example">
        <code>curl -X POST {window.location.origin}/api/v1/logs \</code>
        <code>  -H "X-API-Key: YOUR_API_KEY" \</code>
        <code>  -H "Content-Type: application/json" \</code>
        <code>  -d '{"{"}\"level\": \"info\", \"message\": \"Hello Purl\"{"}"}'</code>
      </div>
    </Card>
  {/if}
</section>

<ConfirmDialog
  bind:show={showRevokeConfirm}
  title="Revoke API Key"
  message="Are you sure you want to revoke the key &quot;{revokingKey?.name || ''}&quot;? Any services using this key will lose access immediately. This action cannot be undone."
  confirmText="Revoke"
  variant="danger"
  onConfirm={handleRevoke}
  onCancel={() => { revokingKey = null; }}
/>

<style>
  .settings-section {
    max-width: 900px;
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .section-header {
    margin-bottom: 4px;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  .error-msg {
    padding: 10px 14px;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid var(--color-error, #f85149);
    border-radius: 6px;
    color: var(--color-error, #f85149);
    font-size: 0.8125rem;
  }

  /* Created key banner */
  .created-key-banner {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 16px;
    background: rgba(56, 139, 253, 0.1);
    border: 1px solid rgba(56, 139, 253, 0.4);
    border-radius: 8px;
  }

  .created-key-header {
    display: flex;
    align-items: center;
    gap: 8px;
    color: #58a6ff;
    font-size: 0.875rem;
  }

  .created-key-warning {
    margin: 0;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
  }

  .created-key-value {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    overflow: hidden;
  }

  .created-key-value code {
    flex: 1;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.8125rem;
    color: #3fb950;
    word-break: break-all;
    user-select: all;
  }

  .copy-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-secondary, #8b949e);
    cursor: pointer;
    flex-shrink: 0;
    transition: all 0.15s ease;
  }

  .copy-btn:hover {
    background: var(--bg-hover, #30363d);
    color: var(--text-primary, #c9d1d9);
    border-color: var(--text-secondary, #8b949e);
  }

  /* Keys header */
  .keys-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
  }

  .key-count {
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
  }

  /* Create form */
  .create-form {
    display: flex;
    gap: 12px;
    align-items: flex-end;
    padding: 12px;
    margin-bottom: 16px;
    background: var(--bg-tertiary, #21262d);
    border-radius: 6px;
    flex-wrap: wrap;
  }

  /* Table layout */
  .keys-table {
    display: flex;
    flex-direction: column;
  }

  .table-header {
    display: grid;
    grid-template-columns: 1fr 120px 150px 80px auto;
    padding: 6px 0;
    border-bottom: 1px solid var(--border-color, #30363d);
    margin-bottom: 4px;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-muted, #6e7681);
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
    border-bottom: 1px solid var(--border-color, #21262d);
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

  .col-name svg {
    color: var(--text-muted, #6e7681);
    flex-shrink: 0;
  }

  .key-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary, #c9d1d9);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-key {
    display: flex;
    align-items: center;
  }

  .key-prefix {
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 4px;
  }

  .col-created {
    display: flex;
    align-items: center;
  }

  .key-date {
    font-size: 0.75rem;
    color: var(--text-muted, #6e7681);
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

  .empty {
    text-align: center;
    padding: 32px 20px;
    color: var(--text-muted, #6e7681);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
  }

  .empty p {
    margin: 0;
    font-size: 0.875rem;
  }

  .empty svg {
    opacity: 0.5;
  }

  /* Info card */
  .info-title {
    margin: 0 0 8px;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
  }

  .info-text {
    margin: 0 0 12px;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
    line-height: 1.5;
  }

  .info-text code {
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 4px;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
    color: var(--text-primary, #c9d1d9);
  }

  .usage-example {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 12px 14px;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #21262d);
    border-radius: 6px;
    overflow-x: auto;
  }

  .usage-example code {
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
    white-space: pre;
    line-height: 1.6;
  }
</style>
