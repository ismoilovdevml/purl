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
  import EnvBadge from '../ui/EnvBadge.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { currentUser } from '../../stores/auth.js';
  import { api } from '../../utils/api.js';
  import IngestSnippet from '../onboarding/IngestSnippet.svelte';
  import CreatedKeyBanner from './apikeys/CreatedKeyBanner.svelte';
  import ApiKeysTable from './apikeys/ApiKeysTable.svelte';

  let keys = $state([]);
  let loading = $state(true);
  let error = $state('');
  let fromEnv = $state(false);

  const isAdmin = $derived($currentUser?.role === 'admin');

  // Create key form
  let showCreateForm = $state(false);
  let newKeyName = $state('');
  let creating = $state(false);

  // Newly created key (shown once)
  let createdKey = $state(null);
  let copied = $state(false);

  // Revoke confirmation
  let showRevokeConfirm = $state(false);
  let revokingKey = $state(null);

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
      <CreatedKeyBanner {createdKey} {copied} oncopy={copyToClipboard} ondismiss={dismissCreatedKey} />
    {/if}

    <Card padding="md">
      <div class="keys-header">
        <span class="key-count">
          {keys.length} key{keys.length !== 1 ? 's' : ''}
          <EnvBadge locked={fromEnv} />
        </span>
        {#if !fromEnv && isAdmin}
          <Button variant="primary" size="sm" onclick={() => { showCreateForm = !showCreateForm; }}>
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
            onenter={handleCreateKey}
          />
          <Button
            variant="success"
            size="sm"
            onclick={handleCreateKey}
            loading={creating}
            disabled={!newKeyName.trim()}
          >
            Create
          </Button>
        </div>
      {/if}

      <ApiKeysTable {keys} canRevoke={!fromEnv && isAdmin} onrevoke={confirmRevoke} />
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
