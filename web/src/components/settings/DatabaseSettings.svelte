<!--
  DatabaseSettings Component
  ClickHouse connection and data retention settings

  Usage:
  <DatabaseSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Input from '../ui/Input.svelte';
  import Button from '../ui/Button.svelte';
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import ClearSecretToggle from '../ui/ClearSecretToggle.svelte';
  import ClearSecretConfirm from '../ui/ClearSecretConfirm.svelte';
  import { formatBytes, formatNumber, formatRelativeTime } from '../../utils/format.js';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import { clearFlags, describeCleared } from '../../utils/clearSecret.js';
  import Icon from '../ui/Icon.svelte';
  import { check, xCircle } from '../ui/icons.js';

  // Server settings state
  let serverSettings = null;
  let loadingSettings = true;

  // Database form
  let dbForm = {
    host: 'localhost',
    port: 8123,
    database: 'purl',
    user: 'default',
    password: ''
  };
  let savingDb = false;
  let dbMessage = null;
  let testingDb = false;
  let dbTestResult = null;

  /*
   * The password is write-only: GET /settings reports password_set, never the
   * value, so posting an empty field means "keep it". Erasing the stored one
   * needs the explicit clear_password instruction — see utils/clearSecret.js.
   */
  let clearPassword = false;
  let clearRequest = null;

  $: passwordStored = !!serverSettings?.clickhouse?.password_set?.value;
  $: passwordFromEnv = !!serverSettings?.clickhouse?.password_set?.from_env;

  // Retention
  let retentionDays = 30;
  let retentionStats = null;
  let savingRetention = false;
  let retentionMessage = null;

  onMount(() => {
    fetchServerSettings();
    fetchRetentionStats();
  });

  async function fetchServerSettings() {
    loadingSettings = true;
    try {
      serverSettings = await api.get('/settings');

      dbForm.host = serverSettings.clickhouse?.host?.value || 'localhost';
      dbForm.port = serverSettings.clickhouse?.port?.value || 8123;
      dbForm.database = serverSettings.clickhouse?.database?.value || 'purl';
      dbForm.user = serverSettings.clickhouse?.user?.value || 'default';
      dbForm.password = '';
      clearPassword = false;

      retentionDays = serverSettings.retention?.days?.value || 30;
    } catch {
      // Ignore
    } finally {
      loadingSettings = false;
    }
  }

  async function fetchRetentionStats() {
    try {
      retentionStats = await api.get('/config/retention');
    } catch {
      // Ignore
    }
  }

  /** Save, but let the user confirm first when it would erase the password. */
  function requestSaveDb() {
    if (clearPassword) {
      clearRequest = { keys: ['password'], run: saveDbSettings };
      return;
    }
    saveDbSettings();
  }

  async function saveDbSettings() {
    savingDb = true;
    dbMessage = null;

    // Snapshot: fetchServerSettings() below disarms the checkbox, and the
    // success text must still describe what this request did.
    const clearing = clearPassword;

    try {
      // Blank alongside the flag on purpose — clear_password with a non-blank
      // password is a 400 ("Cannot clear and set the same field"). The input
      // is disabled while armed, so this only restates what the UI enforces.
      const payload = { ...dbForm, ...clearFlags({ password: clearing }) };
      if (clearing) payload.password = '';

      const data = await api.put('/settings/clickhouse', payload);
      const cleared = describeCleared(data.cleared);

      dbMessage = { success: true, text: cleared ? `${data.message} — ${cleared}` : data.message };
      toastSuccess(cleared || 'Database settings saved');
      fetchServerSettings();
    } catch (err) {
      // Covers the clear-specific 400s ("Not a clearable secret", "Cannot
      // clear and set the same field") and the 409 env guard: api.js lifts the
      // server's `error` into err.message, so none of them are swallowed.
      dbMessage = { success: false, text: err.message };
      toastError('Failed to save database settings: ' + err.message);
    } finally {
      savingDb = false;
    }
  }

  async function testDbConnection() {
    testingDb = true;
    dbTestResult = null;

    try {
      dbTestResult = await api.post('/config/test-clickhouse', dbForm);
      if (dbTestResult.success) {
        toastSuccess('Database connection successful');
      } else {
        toastError('Database connection failed: ' + (dbTestResult.error || 'Unknown error'));
      }
    } catch (err) {
      dbTestResult = { success: false, error: err.message };
      toastError('Database connection test failed: ' + err.message);
    } finally {
      testingDb = false;
    }
  }

  async function saveRetention() {
    savingRetention = true;
    retentionMessage = null;

    try {
      const data = await api.put('/settings/retention', { days: retentionDays });
      retentionMessage = { success: true, text: data.message };
      toastSuccess('Retention settings saved');
      fetchRetentionStats();
    } catch (err) {
      retentionMessage = { success: false, text: err.message };
      toastError('Failed to save retention settings: ' + err.message);
    } finally {
      savingRetention = false;
    }
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Database Configuration</h3>
    <p>Configure ClickHouse connection and data retention</p>
  </div>

  {#if loadingSettings}
    <LoadingSpinner centered label="Loading configuration..." />
  {:else}
    <!-- ClickHouse Connection -->
    <Card padding="none">
      <div class="group-header">
        <span class="group-title">ClickHouse Connection</span>
        {#if serverSettings?.clickhouse?.host?.from_env}
          <Badge variant="warning" size="sm">From Environment</Badge>
        {/if}
      </div>

      <div class="form-grid">
        <Input
          label="Host"
          bind:value={dbForm.host}
          placeholder="localhost"
        />

        <Input
          label="Port"
          type="number"
          bind:value={dbForm.port}
          placeholder="8123"
        />

        <Input
          label="Database"
          bind:value={dbForm.database}
          placeholder="purl"
        />

        <Input
          label="User"
          bind:value={dbForm.user}
          placeholder="default"
        />

        <div class="full-width">
          <Input
            label="Password"
            type="password"
            bind:value={dbForm.password}
            placeholder={clearPassword ? 'Will be removed on save' : (passwordStored ? '********' : 'Enter password')}
            helper={passwordStored && !dbForm.password && !clearPassword ? 'Password is already set. Leave empty to keep current.' : ''}
            envLocked={passwordFromEnv}
            disabled={clearPassword}
            fullWidth
          />
          <ClearSecretToggle
            secret="password"
            stored={passwordStored}
            envLocked={passwordFromEnv}
            bind:armed={clearPassword}
          />
        </div>
      </div>

      <div class="form-actions">
        <Button variant="default" on:click={testDbConnection} loading={testingDb}>
          {testingDb ? 'Testing...' : 'Test Connection'}
        </Button>
        <Button variant="success" on:click={requestSaveDb} loading={savingDb}>
          {savingDb ? 'Saving...' : 'Save Settings'}
        </Button>
      </div>

      {#if dbTestResult}
        <div class="result-box" class:success={dbTestResult.success}>
          {#if dbTestResult.success}
            <Icon icon={check} size={16} strokeWidth={2.25} />
            {dbTestResult.message}
          {:else}
            <Icon icon={xCircle} size={16} />
            {dbTestResult.error}
          {/if}
        </div>
      {/if}

      {#if dbMessage}
        <div class="result-box" class:success={dbMessage.success}>
          {dbMessage.text}
        </div>
      {/if}
    </Card>

    <!-- Retention Settings -->
    <Card padding="none" class="retention-card">
      <div class="group-header">
        <span class="group-title">Data Retention</span>
        {#if serverSettings?.retention?.days?.from_env}
          <Badge variant="warning" size="sm">From Environment</Badge>
        {/if}
      </div>

      <div class="setting-item">
        <div class="setting-info">
          <span class="setting-label">Retention Period</span>
          <span class="setting-hint">How long to keep log data (ClickHouse TTL)</span>
        </div>
        <div class="retention-control">
          <Input
            type="number"
            min={1}
            max={365}
            bind:value={retentionDays}
            size="sm"
          />
          <span class="unit">days</span>
          <Button variant="success" size="sm" on:click={saveRetention} loading={savingRetention}>
            {savingRetention ? 'Saving...' : 'Apply'}
          </Button>
        </div>
      </div>

      {#if retentionMessage}
        <div class="result-box" class:success={retentionMessage.success}>
          {retentionMessage.text}
        </div>
      {/if}

      {#if retentionStats}
        <div class="stats-grid">
          <div class="stat-card">
            <span class="stat-value">{formatNumber(retentionStats.total_logs || 0)}</span>
            <span class="stat-label">Total Logs</span>
          </div>
          <div class="stat-card">
            <span class="stat-value">{formatBytes((retentionStats.db_size_mb || 0) * 1024 * 1024)}</span>
            <span class="stat-label">Database Size</span>
          </div>
          <div class="stat-card">
            <span class="stat-value">{retentionStats.oldest_log ? formatRelativeTime(retentionStats.oldest_log) : 'N/A'}</span>
            <span class="stat-label">Oldest Log</span>
          </div>
          <div class="stat-card">
            <span class="stat-value">{retentionStats.newest_log ? formatRelativeTime(retentionStats.newest_log) : 'N/A'}</span>
            <span class="stat-label">Newest Log</span>
          </div>
        </div>
      {/if}
    </Card>
  {/if}
</section>

<ClearSecretConfirm bind:request={clearRequest} />

<style>
  .settings-section {
    max-width: 800px;
  }

  .section-header {
    margin-bottom: 24px;
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
    background: rgba(33, 38, 45, 0.3);
    border-bottom: 1px solid var(--border-muted);
  }

  .group-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .form-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    padding: 16px;
  }

  .full-width {
    grid-column: 1 / -1;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
  }

  .form-actions {
    display: flex;
    gap: 8px;
    padding: 12px 16px;
    background: rgba(33, 38, 45, 0.3);
    border-top: 1px solid var(--border-muted);
  }

  .result-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    font-size: 0.8125rem;
    color: var(--color-error);
    background: rgba(248, 81, 73, 0.1);
    border-top: 1px solid var(--border-muted);
  }

  .result-box.success {
    color: var(--color-success);
    background: rgba(63, 185, 80, 0.1);
  }

  .setting-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-muted);
  }

  .setting-item:last-child {
    border-bottom: none;
  }

  .setting-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .setting-label {
    font-size: 0.875rem;
    color: var(--text-primary);
  }

  .setting-hint {
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .retention-control {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .retention-control .unit {
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  :global(.retention-card) {
    margin-top: 24px;
  }

  .stats-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
    padding: 16px;
    background: var(--bg-primary);
    border-top: 1px solid var(--border-muted);
  }

  .stat-card {
    text-align: center;
    padding: 12px 8px;
    background: var(--bg-secondary);
    border-radius: 6px;
  }

  .stat-value {
    display: block;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-bright);
    font-family: var(--font-mono);
  }

  .stat-label {
    display: block;
    font-size: 0.6875rem;
    color: var(--text-secondary);
    margin-top: 4px;
  }

</style>
