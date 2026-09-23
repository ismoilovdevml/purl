<!--
  BackupItem
  One entry in Backup History: name, status/S3 badges, date, size, row and
  table counts, any error, and the Download / Upload S3 / Restore / Delete
  actions. BackupSettings owns the requests and the confirmation modals.
-->
<script>
  import Button from '../../ui/Button.svelte';
  import { formatBytes } from '../../../utils/format.js';

  let {
    /** Backup record from GET /backup */
    backup,
    /** S3 upload is enabled: show Upload S3 */
    s3Enabled = false,
    /** This backup is being downloaded */
    downloading = false,
    /** This backup is being uploaded to S3 */
    uploading = false,
    /** This backup is being restored */
    restoring = false,
    /** This backup is being deleted */
    deleting = false,
    /** (backup) => void */
    ondownload,
    /** (backup) => void */
    onuploads3,
    /** (backup) => void — ask to confirm a restore */
    onrestore,
    /** (backup) => void — ask to confirm a delete */
    ondelete,
  } = $props();

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
        loading={downloading}
        onclick={() => ondownload(backup)}
      >
        Download
      </Button>
      {#if s3Enabled}
        <Button
          variant="default"
          size="sm"
          loading={uploading}
          onclick={() => onuploads3(backup)}
        >
          {backup.target_type === 's3' ? 'Re-upload S3' : 'Upload S3'}
        </Button>
      {/if}
      <Button
        variant="default"
        size="sm"
        loading={restoring}
        onclick={() => onrestore(backup)}
      >
        Restore
      </Button>
    {/if}
    <Button
      variant="danger"
      size="sm"
      loading={deleting}
      onclick={() => ondelete(backup)}
    >
      Delete
    </Button>
  </div>
</div>

<style>
  .backup-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-muted);
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
    color: var(--text-primary);
  }

  .backup-meta {
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: 0.75rem;
    color: var(--text-secondary);
    flex-wrap: wrap;
  }

  .backup-tables {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .backup-error {
    font-size: 0.75rem;
    color: var(--color-error);
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
</style>
