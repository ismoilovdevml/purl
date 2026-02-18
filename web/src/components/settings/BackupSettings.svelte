<!--
  BackupSettings Component
  Backup management: create, list, restore, delete

  Usage:
  <BackupSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Button from '../ui/Button.svelte';
  import Card from '../ui/Card.svelte';
  import Input from '../ui/Input.svelte';
  import Modal from '../ui/Modal.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';

  const API_BASE = '/api';

  let backups = [];
  let loading = true;
  let creating = false;
  let restoring = null;
  let deleting = null;
  let backupName = '';
  let message = null;
  let confirmRestore = null;
  let confirmDelete = null;

  onMount(() => {
    fetchBackups();
  });

  async function fetchBackups() {
    loading = true;
    try {
      const res = await fetch(`${API_BASE}/backup`);
      if (res.ok) {
        const data = await res.json();
        backups = data.backups || [];
      }
    } catch {
      message = { success: false, text: 'Failed to load backups' };
    }
    loading = false;
  }

  async function createBackup() {
    creating = true;
    message = null;
    try {
      const res = await fetch(`${API_BASE}/backup`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: backupName || undefined })
      });
      const data = await res.json();
      if (res.ok) {
        message = { success: true, text: `Backup "${data.backup?.name}" created successfully` };
        toastSuccess(`Backup "${data.backup?.name}" created successfully`);
        backupName = '';
        await fetchBackups();
      } else {
        message = { success: false, text: data.error || 'Backup creation failed' };
        toastError('Backup creation failed: ' + (data.error || 'Unknown error'));
      }
    } catch {
      message = { success: false, text: 'Failed to create backup' };
      toastError('Failed to create backup');
    }
    creating = false;
  }

  async function restoreBackup(id) {
    restoring = id;
    message = null;
    confirmRestore = null;
    try {
      const res = await fetch(`${API_BASE}/backup/restore`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id })
      });
      const data = await res.json();
      if (res.ok) {
        const tables = data.restore?.tables?.join(', ') || 'none';
        message = { success: true, text: `Restored ${data.restore?.rows || 0} rows from tables: ${tables}` };
        toastSuccess(`Backup restored: ${data.restore?.rows || 0} rows`);
      } else {
        message = { success: false, text: data.error || 'Restore failed' };
        toastError('Restore failed: ' + (data.error || 'Unknown error'));
      }
    } catch {
      message = { success: false, text: 'Failed to restore backup' };
      toastError('Failed to restore backup');
    }
    restoring = null;
  }

  async function deleteBackup(id) {
    deleting = id;
    message = null;
    confirmDelete = null;
    try {
      const res = await fetch(`${API_BASE}/backup/${encodeURIComponent(id)}`, {
        method: 'DELETE'
      });
      if (res.ok) {
        message = { success: true, text: 'Backup deleted' };
        toastSuccess('Backup deleted');
        await fetchBackups();
      } else {
        const data = await res.json();
        message = { success: false, text: data.error || 'Delete failed' };
        toastError('Failed to delete backup: ' + (data.error || 'Unknown error'));
      }
    } catch {
      message = { success: false, text: 'Failed to delete backup' };
      toastError('Failed to delete backup');
    }
    deleting = null;
  }

  function formatBytes(bytes) {
    if (!bytes || bytes === 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    return (bytes / Math.pow(1024, i)).toFixed(1) + ' ' + units[i];
  }

  function formatDate(dateStr) {
    if (!dateStr) return '—';
    try {
      const d = new Date(dateStr);
      return d.toLocaleString();
    } catch {
      return dateStr;
    }
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Backup Management</h3>
    <p>Create, restore, and manage database backups</p>
  </div>

  {#if message}
    <div class="result-box" class:success={message.success}>
      {message.text}
    </div>
  {/if}

  <Card padding="none">
    <div class="group-header">
      <span class="group-title">Create Backup</span>
    </div>
    <div class="create-form">
      <div class="create-row">
        <Input
          bind:value={backupName}
          placeholder="Backup name (optional, auto-generated if empty)"
          size="sm"
          fullWidth
          on:enter={createBackup}
        />
        <Button
          variant="primary"
          loading={creating}
          on:click={createBackup}
        >
          Create Backup
        </Button>
      </div>
      <p class="create-hint">Exports all tables (logs, alerts, saved searches, audit logs, patterns) as CSV</p>
    </div>
  </Card>

  <Card padding="none">
    <div class="group-header">
      <span class="group-title">Backup History</span>
      <Button variant="ghost" size="sm" on:click={fetchBackups}>Refresh</Button>
    </div>

    {#if loading}
      <div class="empty-state"><LoadingSpinner size="sm" label="Loading backups..." /></div>
    {:else if backups.length === 0}
      <div class="empty-state">No backups found. Create your first backup above.</div>
    {:else}
      <div class="backup-list">
        {#each backups as backup}
          <div class="backup-item">
            <div class="backup-info">
              <div class="backup-name">{backup.name}</div>
              <div class="backup-meta">
                <span class="badge" class:completed={backup.status === 'completed'}
                      class:running={backup.status === 'running'}
                      class:failed={backup.status === 'failed'}>
                  {backup.status}
                </span>
                <span>{formatDate(backup.created_at)}</span>
                <span>{formatBytes(backup.size_bytes)}</span>
                {#if backup.rows_total > 0}
                  <span>{backup.rows_total.toLocaleString()} rows</span>
                {/if}
              </div>
              {#if backup.tables_backed_up}
                <div class="backup-tables">Tables: {backup.tables_backed_up}</div>
              {/if}
              {#if backup.error}
                <div class="backup-error">{backup.error}</div>
              {/if}
            </div>
            <div class="backup-actions">
              {#if backup.status === 'completed'}
                <Button
                  variant="default"
                  size="sm"
                  loading={restoring === backup.id}
                  on:click={() => confirmRestore = backup}
                >
                  Restore
                </Button>
              {/if}
              <Button
                variant="danger"
                size="sm"
                loading={deleting === backup.id}
                on:click={() => confirmDelete = backup}
              >
                Delete
              </Button>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </Card>
</section>

<!-- Restore confirmation modal -->
{#if confirmRestore}
  <Modal bind:open={confirmRestore} title="Confirm Restore" size="sm">
    <p>Are you sure you want to restore from backup <strong>{confirmRestore.name}</strong>?</p>
    <p class="warning-text">This will import data into existing tables. Existing data will not be deleted, but duplicates may occur.</p>
    <svelte:fragment slot="footer">
      <Button variant="default" on:click={() => confirmRestore = null}>Cancel</Button>
      <Button variant="primary" on:click={() => restoreBackup(confirmRestore.id)}>Restore</Button>
    </svelte:fragment>
  </Modal>
{/if}

<!-- Delete confirmation modal -->
{#if confirmDelete}
  <Modal bind:open={confirmDelete} title="Confirm Delete" size="sm">
    <p>Are you sure you want to delete backup <strong>{confirmDelete.name}</strong>?</p>
    <p class="warning-text">This action cannot be undone. Backup files will be permanently removed.</p>
    <svelte:fragment slot="footer">
      <Button variant="default" on:click={() => confirmDelete = null}>Cancel</Button>
      <Button variant="danger" on:click={() => deleteBackup(confirmDelete.id)}>Delete</Button>
    </svelte:fragment>
  </Modal>
{/if}

<style>
  .settings-section {
    max-width: 900px;
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .section-header {
    margin-bottom: 0;
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

  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .group-title {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary, #8b949e);
  }

  .create-form {
    padding: 16px;
  }

  .create-row {
    display: flex;
    gap: 12px;
    align-items: flex-start;
  }

  .create-hint {
    font-size: 0.75rem;
    color: var(--text-muted, #6e7681);
    margin: 8px 0 0;
  }

  .empty-state {
    padding: 32px 16px;
    text-align: center;
    color: var(--text-secondary, #8b949e);
    font-size: 0.875rem;
  }

  .backup-list {
    display: flex;
    flex-direction: column;
  }

  .backup-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
    gap: 16px;
  }

  .backup-item:last-child {
    border-bottom: none;
  }

  .backup-info {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .backup-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary, #c9d1d9);
  }

  .backup-meta {
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
  }

  .backup-tables {
    font-size: 0.75rem;
    color: var(--text-muted, #6e7681);
  }

  .backup-error {
    font-size: 0.75rem;
    color: var(--color-error, #f85149);
  }

  .badge {
    display: inline-block;
    padding: 1px 8px;
    border-radius: 9999px;
    font-size: 0.7rem;
    font-weight: 500;
    text-transform: uppercase;
  }

  .badge.completed {
    background: rgba(63, 185, 80, 0.15);
    color: #3fb950;
  }

  .badge.running {
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
  }

  .badge.failed {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
  }

  .backup-actions {
    display: flex;
    gap: 8px;
    flex-shrink: 0;
  }

  .result-box {
    padding: 10px 14px;
    border-radius: 6px;
    font-size: 0.85rem;
    background: rgba(248, 81, 73, 0.1);
    color: #f85149;
    border: 1px solid rgba(248, 81, 73, 0.2);
  }

  .result-box.success {
    background: rgba(63, 185, 80, 0.1);
    color: #3fb950;
    border-color: rgba(63, 185, 80, 0.2);
  }

  .warning-text {
    font-size: 0.85rem;
    color: var(--color-warning, #d29922);
    margin-top: 8px;
  }
</style>
