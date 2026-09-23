<!--
  BackupSettings Component
  Backup management: create, list, restore, delete, download.
  Schedule and S3 configuration live in BackupConfig.svelte.

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
  import BackupConfig from './BackupConfig.svelte';
  import BackupItem from './backup/BackupItem.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import { downloadBlob } from '../../utils/dom.js';

  const API_BASE = '/api';

  // Backup list state
  let backups = $state([]);
  let loading = $state(true);
  let creating = $state(false);
  let restoring = $state(null);
  let deleting = $state(null);
  let downloading = $state(null);
  let uploadingS3 = $state(null);
  let backupName = $state('');
  let message = $state(null);
  let confirmRestore = $state(null);
  let confirmDelete = $state(null);

  // Owned here because Backup History shows its "Upload S3" button off the
  // live toggle; <BackupConfig> fills and edits it through the binding.
  let s3Config = $state({
    enabled: false,
    bucket: '',
    region: 'us-east-1',
    prefix: 'purl-backups/',
    endpoint: '',
    has_credentials: false,
    // Coarse flag: PURL_BACKUP_S3_ENABLED only.
    from_env: false,
    from_env_keys: {},
  });

  onMount(() => {
    fetchBackups();
  });

  // ============================================
  // Backup CRUD
  // ============================================
  async function fetchBackups() {
    loading = true;
    try {
      const data = await api.get('/backup');
      backups = data.backups || [];
    } catch {
      message = { success: false, text: 'Failed to load backups' };
    }
    loading = false;
  }

  async function createBackup() {
    creating = true;
    message = null;
    try {
      const data = await api.post('/backup', { name: backupName || undefined });
      message = { success: true, text: `Backup "${data.backup?.name}" created successfully` };
      toastSuccess(`Backup "${data.backup?.name}" created successfully`);
      backupName = '';
      await fetchBackups();
    } catch (err) {
      message = { success: false, text: err.message || 'Backup creation failed' };
      toastError('Backup creation failed: ' + (err.message || 'Unknown error'));
    }
    creating = false;
  }

  async function restoreBackup(id) {
    restoring = id;
    message = null;
    confirmRestore = null;
    try {
      const data = await api.post('/backup/restore', { id });
      const tables = data.restore?.tables?.join(', ') || 'none';
      message = { success: true, text: `Restored ${data.restore?.rows || 0} rows from tables: ${tables}` };
      toastSuccess(`Backup restored: ${data.restore?.rows || 0} rows`);
    } catch (err) {
      message = { success: false, text: err.message || 'Restore failed' };
      toastError('Restore failed: ' + (err.message || 'Unknown error'));
    }
    restoring = null;
  }

  async function deleteBackup(id) {
    deleting = id;
    message = null;
    confirmDelete = null;
    try {
      await api.del(`/backup/${encodeURIComponent(id)}`);
      message = { success: true, text: 'Backup deleted' };
      toastSuccess('Backup deleted');
      await fetchBackups();
    } catch (err) {
      message = { success: false, text: err.message || 'Delete failed' };
      toastError('Failed to delete backup: ' + (err.message || 'Unknown error'));
    }
    deleting = null;
  }

  // ============================================
  // Download
  // ============================================
  async function downloadBackup(id, name) {
    downloading = id;
    try {
      // Raw fetch on purpose: this endpoint returns a binary tarball and
      // utils/api.js parses every response as text/JSON, which would corrupt it.
      const res = await fetch(`${API_BASE}/backup/${encodeURIComponent(id)}/download`);
      if (res.ok) {
        downloadBlob(await res.blob(), `${name || id}.tar.gz`);
        toastSuccess('Backup downloaded');
      } else {
        const data = await res.json().catch(() => ({}));
        toastError('Download failed: ' + (data.error || 'Unknown error'));
      }
    } catch {
      toastError('Failed to download backup');
    }
    downloading = null;
  }

  // ============================================
  // S3 upload
  // ============================================
  async function uploadToS3(id) {
    uploadingS3 = id;
    try {
      await api.post('/backup/upload-s3', { id });
      toastSuccess('Backup uploaded to S3');
      await fetchBackups();
    } catch (err) {
      toastError('S3 upload failed: ' + (err.message || 'Unknown error'));
    }
    uploadingS3 = null;
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

  <!-- Create Backup -->
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
          onenter={createBackup}
        />
        <Button
          variant="primary"
          loading={creating}
          onclick={createBackup}
        >
          Create Backup
        </Button>
      </div>
      <p class="create-hint">Exports all tables (logs, alerts, saved searches, audit logs, patterns) as CSV</p>
    </div>
  </Card>

  <BackupConfig bind:s3Config />

  <!-- Backup History -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">Backup History</span>
      <Button variant="ghost" size="sm" onclick={fetchBackups}>Refresh</Button>
    </div>

    {#if loading}
      <div class="empty-state"><LoadingSpinner size="sm" label="Loading backups..." /></div>
    {:else if backups.length === 0}
      <div class="empty-state">No backups found. Create your first backup above.</div>
    {:else}
      <div class="backup-list">
        {#each backups as backup}
          <BackupItem
            {backup}
            s3Enabled={s3Config.enabled}
            downloading={downloading === backup.id}
            uploading={uploadingS3 === backup.id}
            restoring={restoring === backup.id}
            deleting={deleting === backup.id}
            ondownload={(b) => downloadBackup(b.id, b.name)}
            onuploads3={(b) => uploadToS3(b.id)}
            onrestore={(b) => { confirmRestore = b; }}
            ondelete={(b) => { confirmDelete = b; }}
          />
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
    {#snippet footer()}
      <Button variant="default" onclick={() => confirmRestore = null}>Cancel</Button>
      <Button variant="primary" onclick={() => restoreBackup(confirmRestore.id)}>Restore</Button>
    {/snippet}
  </Modal>
{/if}

<!-- Delete confirmation modal -->
{#if confirmDelete}
  <Modal bind:open={confirmDelete} title="Confirm Delete" size="sm">
    <p>Are you sure you want to delete backup <strong>{confirmDelete.name}</strong>?</p>
    <p class="warning-text">This action cannot be undone. Backup files will be permanently removed.</p>
    {#snippet footer()}
      <Button variant="default" onclick={() => confirmDelete = null}>Cancel</Button>
      <Button variant="danger" onclick={() => deleteBackup(confirmDelete.id)}>Delete</Button>
    {/snippet}
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
    color: var(--text-bright);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin: 0;
  }

  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-muted);
  }

  .group-title {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary);
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
    color: var(--text-muted);
    margin: 8px 0 0;
  }
  /* Sits under the credential input it belongs to, aligned with the input
     column rather than the 260px label column. */
  /* Nothing stored => the toggle renders nothing => no blank row. */

  .empty-state {
    padding: 32px 16px;
    text-align: center;
    color: var(--text-secondary);
    font-size: 0.875rem;
  }

  .backup-list {
    display: flex;
    flex-direction: column;
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
    color: var(--color-warning);
    margin-top: 8px;
  }
</style>
