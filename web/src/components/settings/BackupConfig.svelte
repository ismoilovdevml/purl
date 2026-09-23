<!--
  BackupConfig Component
  Backup configuration: the backup schedule and the S3 remote-storage target.
  Split out of BackupSettings, which keeps the create/list/restore flow.

  s3Config is bindable because Backup History reads its live `enabled` flag to
  decide whether to offer "Upload S3". The parent must pass an initialised
  object — this component fills it from GET /backup/s3.

  Usage:
  <BackupConfig bind:s3Config />
-->
<script>
  import { onMount } from 'svelte';
  import Button from '../ui/Button.svelte';
  import Card from '../ui/Card.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import EnvBadge from '../ui/EnvBadge.svelte';
  import BackupFieldRow from './backup/BackupFieldRow.svelte';
  import ClearSecretToggle from '../ui/ClearSecretToggle.svelte';
  import ClearSecretConfirm from '../ui/ClearSecretConfirm.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import { isEnvLocked } from '../../utils/envLock.js';
  import { clearFlags, describeCleared } from '../../utils/clearSecret.js';

  let {
    /** S3 target config, owned by the parent and filled here. */
    s3Config = $bindable(),
  } = $props();

  // Schedule state
  let schedule = $state({
    enabled: false,
    interval_hours: 24,
    retention_days: 30,
    // Coarse flag: PURL_BACKUP_SCHEDULE_ENABLED only.
    from_env: false,
    // Per-key truth for every backup.* key %ENV_MAP can manage.
    from_env_keys: {},
  });
  let loadingSchedule = $state(true);
  let savingSchedule = $state(false);

  // The whole panel is frozen by the coarse flag; individual fields are frozen
  // by their own variable. Both must disable a control, or the save 409s on a
  // field that looked editable.
  const scheduleEnv = $derived(schedule.from_env_keys);
  const s3Env = $derived(s3Config.from_env_keys);
  let loadingS3 = $state(true);
  let savingS3 = $state(false);
  let s3AccessKey = $state('');
  let s3SecretKey = $state('');

  /*
   * Both credentials are write-only — GET /backup/s3 answers a single
   * has_credentials flag and never the values — so an empty input means "keep
   * what is stored". Removing one needs the explicit clear_s3_access_key /
   * clear_s3_secret_key instruction (see utils/clearSecret.js).
   *
   * has_credentials gates BOTH controls because it is the only "is anything
   * stored" signal the endpoint offers; a per-key flag would let the secret
   * key's control appear on its own.
   */
  let clearingS3 = $state({ s3_access_key: false, s3_secret_key: false });
  let clearRequest = $state(null);

  onMount(() => {
    fetchSchedule();
    fetchS3Config();
  });

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

  /** Credentials the user armed for removal. */
  function pendingS3Clears() {
    return Object.keys(clearingS3).filter((key) => clearingS3[key]);
  }

  /** Save, but let the user confirm first when it would erase a credential. */
  function requestSaveS3() {
    const armed = pendingS3Clears();
    if (armed.length) {
      clearRequest = { keys: armed, run: saveS3Config };
      return;
    }
    saveS3Config();
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
        // Only the armed ones; a disarmed clear_* is a no-op the request has
        // no business carrying.
        ...clearFlags(clearingS3),
      };
      // Guarded by the inputs being disabled while armed, but restated here:
      // clear_x with a non-blank x is a 400, not a removal.
      if (s3AccessKey && !clearingS3.s3_access_key) payload.s3_access_key = s3AccessKey;
      if (s3SecretKey && !clearingS3.s3_secret_key) payload.s3_secret_key = s3SecretKey;

      const data = await api.put('/backup/s3', payload);
      const cleared = describeCleared(data?.cleared);

      toastSuccess(cleared || 'S3 settings saved');
      s3AccessKey = '';
      s3SecretKey = '';
      clearingS3 = { s3_access_key: false, s3_secret_key: false };
      await fetchS3Config();
    } catch (err) {
      // Includes the clear-specific 400s ("Not a clearable secret", "Cannot
      // clear and set the same field") and the 409 env guard — api.js lifts the
      // server's `error` into err.message, so nothing is swallowed silently.
      toastError('Failed to save S3 settings: ' + (err.message || 'Unknown error'));
    }
    savingS3 = false;
  }
</script>

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
        disabled={schedule.from_env || isEnvLocked(scheduleEnv, 'schedule_enabled')}
      />

      {#if schedule.enabled}
        <div class="schedule-fields">
          <BackupFieldRow
            id="backup-interval"
            label="Backup interval (hours)"
            locked={isEnvLocked(scheduleEnv, 'schedule_interval_hours')}
            type="number"
            bind:value={schedule.interval_hours}
            min="1"
            max="168"
            disabled={schedule.from_env || isEnvLocked(scheduleEnv, 'schedule_interval_hours')}
          />
          <BackupFieldRow
            id="backup-retention"
            label="Auto-delete backups older than (days)"
            locked={isEnvLocked(scheduleEnv, 'retention_days')}
            type="number"
            bind:value={schedule.retention_days}
            min="1"
            max="365"
            disabled={schedule.from_env || isEnvLocked(scheduleEnv, 'retention_days')}
          />
        </div>
      {/if}

      <div class="schedule-actions">
        <Button
          variant="primary"
          size="sm"
          loading={savingSchedule}
          disabled={schedule.from_env}
          onclick={saveSchedule}
        >
          Save Schedule
        </Button>
        <EnvBadge locked={schedule.from_env} label="Configured via ENV" />
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
        disabled={s3Config.from_env || isEnvLocked(s3Env, 's3_enabled')}
      />

      {#if s3Config.enabled}
        <div class="schedule-fields">
          <BackupFieldRow
            id="s3-bucket"
            label="S3 Bucket"
            locked={isEnvLocked(s3Env, 's3_bucket')}
            wide
            bind:value={s3Config.bucket}
            placeholder="my-backups-bucket"
            disabled={s3Config.from_env || isEnvLocked(s3Env, 's3_bucket')}
          />
          <BackupFieldRow
            id="s3-region"
            label="Region"
            locked={isEnvLocked(s3Env, 's3_region')}
            bind:value={s3Config.region}
            placeholder="us-east-1"
            disabled={s3Config.from_env || isEnvLocked(s3Env, 's3_region')}
          />
          <BackupFieldRow
            id="s3-prefix"
            label="Key Prefix"
            locked={isEnvLocked(s3Env, 's3_prefix')}
            bind:value={s3Config.prefix}
            placeholder="purl-backups/"
            disabled={s3Config.from_env || isEnvLocked(s3Env, 's3_prefix')}
          />
          <BackupFieldRow
            id="s3-endpoint"
            label="Custom Endpoint (optional)"
            locked={isEnvLocked(s3Env, 's3_endpoint')}
            wide
            bind:value={s3Config.endpoint}
            placeholder="https://minio.example.com"
            disabled={s3Config.from_env || isEnvLocked(s3Env, 's3_endpoint')}
          />
          <BackupFieldRow
            id="s3-access-key"
            label="Access Key ID"
            locked={isEnvLocked(s3Env, 's3_access_key')}
            bind:value={s3AccessKey}
            placeholder={clearingS3.s3_access_key ? 'Removed on save' : (s3Config.has_credentials ? '••••••••' : 'AKIA...')}
            disabled={s3Config.from_env || isEnvLocked(s3Env, 's3_access_key') || clearingS3.s3_access_key}
          />
          <div class="field-row clear-row">
            <ClearSecretToggle
              secret="s3_access_key"
              stored={s3Config.has_credentials}
              envLocked={isEnvLocked(s3Env, 's3_access_key')}
              disabled={s3Config.from_env}
              bind:armed={clearingS3.s3_access_key}
            />
          </div>
          <BackupFieldRow
            id="s3-secret-key"
            label="Secret Access Key"
            locked={isEnvLocked(s3Env, 's3_secret_key')}
            type="password"
            wide
            bind:value={s3SecretKey}
            placeholder={clearingS3.s3_secret_key ? 'Removed on save' : (s3Config.has_credentials ? '••••••••' : 'Secret key')}
            disabled={s3Config.from_env || isEnvLocked(s3Env, 's3_secret_key') || clearingS3.s3_secret_key}
          />
          <div class="field-row clear-row">
            <ClearSecretToggle
              secret="s3_secret_key"
              stored={s3Config.has_credentials}
              envLocked={isEnvLocked(s3Env, 's3_secret_key')}
              disabled={s3Config.from_env}
              bind:armed={clearingS3.s3_secret_key}
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
          onclick={requestSaveS3}
        >
          Save S3 Settings
        </Button>
        <EnvBadge locked={s3Config.from_env} label="Configured via ENV" />
      </div>
    {/if}
  </div>
</Card>

<!-- Second step of the guard around erasing a stored S3 credential -->
<ClearSecretConfirm bind:request={clearRequest} />

<style>
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

  .create-hint {
    font-size: 0.75rem;
    color: var(--text-muted);
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

  /* Sits under the credential input it belongs to, aligned with the input
     column rather than the 260px label column. */
  .clear-row {
    padding-left: 272px;
  }
  /* Nothing stored => the toggle renders nothing => no blank row. */
  .clear-row:empty {
    display: none;
  }

  .schedule-actions {
    display: flex;
    align-items: center;
    gap: 12px;
  }
</style>
