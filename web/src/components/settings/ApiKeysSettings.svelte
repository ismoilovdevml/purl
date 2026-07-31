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
  import { currentUser } from '../../stores/auth.js';
  import { api } from '../../utils/api.js';
  import Icon from '../ui/Icon.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import IngestSnippet from '../onboarding/IngestSnippet.svelte';
  import { check, copy, key as keyIcon, shield } from '../ui/icons.js';

  let keys = [];
  let loading = true;
  let error = '';
  let fromEnv = false;

  $: isAdmin = $currentUser?.role === 'admin';

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
      const data = await api.get('/settings/api-keys');
      keys = data.api_keys || [];
      fromEnv = !!data.from_env;
    } catch (err) {
      error = err.message || 'Failed to load API keys';
    } finally {
      loading = false;
    }
  }

  async function handleCreateKey() {
    if (!newKeyName.trim()) return;
    creating = true;
    try {
      const data = await api.post('/settings/api-keys', { label: newKeyName.trim() });
      createdKey = { key: data.api_key, label: data.label };
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
      await api.del(`/settings/api-keys/${revokingKey.id}`);
      toastSuccess(`API key "${revokingKey.label || revokingKey.id}" revoked`);
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
          <Icon icon={shield} size={16} />
          <strong>New API Key Created</strong>
        </div>
        <p class="created-key-warning">
          Copy this key now. You will not be able to see it again.
        </p>
        <div class="created-key-value">
          <code>{createdKey.key}</code>
          <button
            type="button"
            class="copy-btn"
            on:click={() => copyToClipboard(createdKey.key)}
            title="Copy to clipboard"
            aria-label={copied ? 'API key copied to clipboard' : 'Copy API key to clipboard'}
          >
            <Icon icon={copied ? check : copy} size={16} />
          </button>
        </div>
        <Button variant="ghost" size="sm" on:click={dismissCreatedKey}>Dismiss</Button>
      </div>
    {/if}

    <Card padding="md">
      <div class="keys-header">
        <span class="key-count">
          {keys.length} key{keys.length !== 1 ? 's' : ''}
          {#if fromEnv}<span class="env-badge">ENV</span>{/if}
        </span>
        {#if !fromEnv && isAdmin}
          <Button variant="primary" size="sm" on:click={() => { showCreateForm = !showCreateForm; }}>
            {showCreateForm ? 'Cancel' : 'Create Key'}
          </Button>
        {:else if fromEnv}
          <span class="env-note">Configured via PURL_API_KEYS</span>
        {/if}
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
                {#if !fromEnv && isAdmin}
                  <Button variant="ghost" size="sm" on:click={() => confirmRevoke(key)}>
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
    </Card>

    <Card padding="md">
      <h4 class="info-title">Usage</h4>
      <p class="info-text">
        Include the API key in your log ingestion requests using the <code>X-API-Key</code> header
        or the <code>Authorization: Bearer</code> header.
      </p>
      <IngestSnippet />
    </Card>
  {/if}
</section>

<ConfirmDialog
  bind:show={showRevokeConfirm}
  title="Revoke API Key"
  message={`Are you sure you want to revoke the key "${revokingKey?.label || revokingKey?.id || ''}"? Any services using this key will lose access immediately. This action cannot be undone.`}
  confirmText='Revoke'
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
    color: var(--text-bright);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin: 0;
  }

  .error-msg {
    padding: 10px 14px;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid var(--color-error);
    border-radius: 6px;
    color: var(--color-error);
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
    color: var(--text-secondary);
  }

  .created-key-value {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    overflow: hidden;
  }

  .created-key-value code {
    flex: 1;
    font-family: var(--font-mono);
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
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-secondary);
    cursor: pointer;
    flex-shrink: 0;
    transition: all 0.15s ease;
  }

  .copy-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
    border-color: var(--text-secondary);
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
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .env-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 0.6875rem;
    font-weight: 600;
    letter-spacing: 0.04em;
    background: rgba(187, 128, 9, 0.15);
    color: #d29922;
  }

  .env-note {
    font-size: 0.75rem;
    color: var(--text-muted);
    font-style: italic;
  }

  /* Create form */
  .create-form {
    display: flex;
    gap: 12px;
    align-items: flex-end;
    padding: 12px;
    margin-bottom: 16px;
    background: var(--bg-tertiary);
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

  /* Info card */
  .info-title {
    margin: 0 0 8px;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-bright);
  }

  .info-text {
    margin: 0 0 12px;
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .info-text code {
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 4px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--text-primary);
  }

  /* The curl example lives in onboarding/IngestSnippet.svelte, which brings
     its own styles — the old .usage-example block was a duplicate of it. */
</style>
