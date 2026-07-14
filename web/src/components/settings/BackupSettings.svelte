<!--
  BackupSettings Component
  Backup management: create, list, restore, delete, download, schedule, S3

  Usage:
  <BackupSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Button from '../ui/Button.svelte';
  import Card from '../ui/Card.svelte';
  import Input from '../ui/Input.svelte';
  import Modal from '../ui/Modal.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';

  const API_BASE = '/api';

  // Backup list state
  let backups = [];
  let loading = true;
  let creating = false;
  let restoring = null;
  let deleting = null;
  let downloading = null;
  let uploadingS3 = null;
  let backupName = '';
  let message = null;
  let confirmRestore = null;
  let confirmDelete = null;

  // Schedule state
  let schedule = {
    enabled: false,
    interval_hours: 24,
    retention_days: 30,
    from_env: false,
  };
  let loadingSchedule = true;
  let savingSchedule = false;

  // S3 state
  let s3Config = {
    enabled: false,
    bucket: '',
    region: 'us-east-1',
    prefix: 'purl-backups/',
    endpoint: '',
    has_credentials: false,
    from_env: false,
  };
  let loadingS3 = true;
  let savingS3 = false;
  let s3AccessKey = '';
  let s3SecretKey = '';

  onMount(() => {
    fetchBackups();
    fetchSchedule();
    fetchS3Config();
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
      const res = await fetch(`${API_BASE}/backup/${encodeURIComponent(id)}/download`);
      if (res.ok) {
        const blob = await res.blob();
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `${name || id}.tar.gz`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
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
  // Schedule
  // ============================================
  async function fetchSchedule() {
    loadingSchedule = true;
    try {
      const data = await api.get('/backup/schedule');
      schedule = data.schedule || schedule;
    } catch { /* ignore */ }
    loadingSchedule = false;
  }

  async function saveSchedule() {
    savingSchedule = true;
    try {
      await api.put('/backup/schedule', {
        enabled: schedule.enabled,
        interval_hours: schedule.interval_hours,
        retention_days: schedule.retention_days,
      });
      toastSuccess('Backup schedule saved. Restart required to apply.');
    } catch (err) {
      toastError('Failed to save schedule: ' + (err.message || 'Unknown error'));
    }
    savingSchedule = false;
  }

  // ============================================
  // S3
  // ============================================
  async function fetchS3Config() {
    loadingS3 = true;
    try {
      const data = await api.get('/backup/s3');
      s3Config = data.s3 || s3Config;
    } catch { /* ignore */ }
    loadingS3 = false;
  }

  async function saveS3Config() {
    savingS3 = true;
    try {
      const payload = {
        s3_enabled: s3Config.enabled,
        s3_bucket: s3Config.bucket,
        s3_region: s3Config.region,
        s3_prefix: s3Config.prefix,
        s3_endpoint: s3Config.endpoint,
      };
      if (s3AccessKey) payload.s3_access_key = s3AccessKey;
      if (s3SecretKey) payload.s3_secret_key = s3SecretKey;

      await api.put('/backup/s3', payload);
      toastSuccess('S3 settings saved');
      s3AccessKey = '';
      s3SecretKey = '';
      await fetchS3Config();
    } catch (err) {
      toastError('Failed to save S3 settings: ' + (err.message || 'Unknown error'));
    }
    savingS3 = false;
  }

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

  // ============================================
  // Formatters
  // ============================================
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

  <!-- Scheduled Backups -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">Scheduled Backups</span>
    </div>
    <div class="schedule-form">
      {#if loadingSchedule}
        <LoadingSpinner size="sm" label="Loading schedule..." />
      {:else}
        <Toggle
          bind:checked={schedule.enabled}
          label="Enable scheduled backups"
          description="Automatically create backups at a regular interval"
          disabled={schedule.from_env}
        />

        {#if schedule.enabled}
          <div class="schedule-fields">
            <div class="field-row">
              <label class="field-label" for="backup-interval">Backup interval (hours)</label>
              <input
                id="backup-interval"
                type="number"
                class="field-input"
                bind:value={schedule.interval_hours}
                min="1"
                max="168"
                disabled={schedule.from_env}
              />
            </div>
            <div class="field-row">
              <label class="field-label" for="backup-retention">Auto-delete backups older than (days)</label>
              <input
                id="backup-retention"
                type="number"
                class="field-input"
                bind:value={schedule.retention_days}
                min="1"
                max="365"
                disabled={schedule.from_env}
              />
            </div>
          </div>
        {/if}

        <div class="schedule-actions">
          <Button
            variant="primary"
            size="sm"
            loading={savingSchedule}
            disabled={schedule.from_env}
            on:click={saveSchedule}
          >
            Save Schedule
          </Button>
          {#if schedule.from_env}
            <span class="env-badge">Configured via ENV</span>
          {/if}
        </div>
        <p class="create-hint">Changes require a server restart to take effect</p>
      {/if}
    </div>
  </Card>

  <!-- S3 Remote Storage -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">S3 Remote Storage</span>
    </div>
    <div class="schedule-form">
      {#if loadingS3}
        <LoadingSpinner size="sm" label="Loading S3 config..." />
      {:else}
        <Toggle
          bind:checked={s3Config.enabled}
          label="Enable S3 upload"
          description="Upload backup archives to Amazon S3 or S3-compatible storage (MinIO)"
          disabled={s3Config.from_env}
        />

        {#if s3Config.enabled}
          <div class="schedule-fields">
            <div class="field-row">
              <label class="field-label" for="s3-bucket">S3 Bucket</label>
              <input
                id="s3-bucket"
                type="text"
                class="field-input field-input-wide"
                bind:value={s3Config.bucket}
                placeholder="my-backups-bucket"
                disabled={s3Config.from_env}
              />
            </div>
            <div class="field-row">
              <label class="field-label" for="s3-region">Region</label>
              <input
                id="s3-region"
                type="text"
                class="field-input"
                bind:value={s3Config.region}
                placeholder="us-east-1"
                disabled={s3Config.from_env}
              />
            </div>
            <div class="field-row">
              <label class="field-label" for="s3-prefix">Key Prefix</label>
              <input
                id="s3-prefix"
                type="text"
                class="field-input"
                bind:value={s3Config.prefix}
                placeholder="purl-backups/"
                disabled={s3Config.from_env}
              />
            </div>
            <div class="field-row">
              <label class="field-label" for="s3-endpoint">Custom Endpoint (optional)</label>
              <input
                id="s3-endpoint"
                type="text"
                class="field-input field-input-wide"
                bind:value={s3Config.endpoint}
                placeholder="https://minio.example.com"
                disabled={s3Config.from_env}
              />
            </div>
            <div class="field-row">
              <label class="field-label" for="s3-access-key">Access Key ID</label>
              <input
                id="s3-access-key"
                type="text"
                class="field-input"
                bind:value={s3AccessKey}
                placeholder={s3Config.has_credentials ? '••••••••' : 'AKIA...'}
                disabled={s3Config.from_env}
              />
            </div>
            <div class="field-row">
              <label class="field-label" for="s3-secret-key">Secret Access Key</label>
              <input
                id="s3-secret-key"
                type="password"
                class="field-input field-input-wide"
                bind:value={s3SecretKey}
                placeholder={s3Config.has_credentials ? '••••••••' : 'Secret key'}
                disabled={s3Config.from_env}
              />
            </div>
          </div>
        {/if}

        <div class="schedule-actions">
          <Button
            variant="primary"
            size="sm"
            loading={savingS3}
            disabled={s3Config.from_env}
            on:click={saveS3Config}
          >
            Save S3 Settings
          </Button>
          {#if s3Config.from_env}
            <span class="env-badge">Configured via ENV</span>
          {/if}
        </div>
      {/if}
    </div>
  </Card>

  <!-- Backup History -->
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
                {#if backup.target_type === 's3'}
                  <span class="badge s3">S3</span>
                {/if}
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
                  loading={downloading === backup.id}
                  on:click={() => downloadBackup(backup.id, backup.name)}
                >
                  Download
                </Button>
                {#if s3Config.enabled}
                  <Button
                    variant="default"
                    size="sm"
                    loading={uploadingS3 === backup.id}
                    on:click={() => uploadToS3(backup.id)}
                  >
                    {backup.target_type === 's3' ? 'Re-upload S3' : 'Upload S3'}
                  </Button>
                {/if}
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

  .schedule-form {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .schedule-fields {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-left: 48px;
  }

  .field-row {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .field-label {
    font-size: 0.85rem;
    color: var(--text-secondary, #8b949e);
    min-width: 260px;
    flex-shrink: 0;
  }

  .field-input {
    background: var(--bg-tertiary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-primary, #c9d1d9);
    padding: 6px 10px;
    font-size: 0.85rem;
    width: 140px;
  }

  .field-input-wide {
    width: 280px;
  }

  .field-input:focus {
    outline: none;
    border-color: var(--color-primary, #58a6ff);
    box-shadow: 0 0 0 2px rgba(88, 166, 255, 0.15);
  }

  .field-input:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .schedule-actions {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .env-badge {
    font-size: 0.75rem;
    color: var(--color-warning, #d29922);
    padding: 2px 8px;
    border: 1px solid rgba(210, 153, 34, 0.3);
    border-radius: 4px;
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
    flex-wrap: wrap;
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

  .badge.s3 {
    background: rgba(255, 153, 0, 0.15);
    color: #ff9900;
  }

  .backup-actions {
    display: flex;
    gap: 8px;
    flex-shrink: 0;
    flex-wrap: wrap;
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
