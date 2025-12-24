<!--
  DatabaseSettings Component
  ClickHouse connection and data retention settings

  Usage:
  <DatabaseSettings />
-->
<script>
  import { onMount } from 'svelte';

  const API_BASE = '/api';

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

  // Retention
  let retentionDays = 30;
  let retentionStats = null;
  let savingRetention = false;
  let retentionMessage = null;

  onMount(() => {
    fetchServerSettings();
    fetchRetentionStats();
  });

  function getHeaders() {
    return { 'Content-Type': 'application/json' };
  }

  async function fetchServerSettings() {
    loadingSettings = true;
    try {
      const res = await fetch(`${API_BASE}/settings`, { headers: getHeaders() });
      if (res.ok) {
        serverSettings = await res.json();

        dbForm.host = serverSettings.clickhouse?.host?.value || 'localhost';
        dbForm.port = serverSettings.clickhouse?.port?.value || 8123;
        dbForm.database = serverSettings.clickhouse?.database?.value || 'purl';
        dbForm.user = serverSettings.clickhouse?.user?.value || 'default';
        dbForm.password = '';

        retentionDays = serverSettings.retention?.days?.value || 30;
      }
    } catch {
      // Ignore
    } finally {
      loadingSettings = false;
    }
  }

  async function fetchRetentionStats() {
    try {
      const res = await fetch(`${API_BASE}/config/retention`, { headers: getHeaders() });
      if (res.ok) {
        retentionStats = await res.json();
      }
    } catch {
      // Ignore
    }
  }

  async function saveDbSettings() {
    savingDb = true;
    dbMessage = null;

    try {
      const res = await fetch(`${API_BASE}/settings/clickhouse`, {
        method: 'PUT',
        headers: getHeaders(),
        body: JSON.stringify(dbForm)
      });

      const data = await res.json();
      if (res.ok) {
        dbMessage = { success: true, text: data.message };
        fetchServerSettings();
      } else {
        dbMessage = { success: false, text: data.error };
      }
    } catch (err) {
      dbMessage = { success: false, text: err.message };
    } finally {
      savingDb = false;
    }
  }

  async function testDbConnection() {
    testingDb = true;
    dbTestResult = null;

    try {
      const res = await fetch(`${API_BASE}/config/test-clickhouse`, {
        method: 'POST',
        headers: getHeaders(),
        body: JSON.stringify(dbForm)
      });

      dbTestResult = await res.json();
    } catch (err) {
      dbTestResult = { success: false, error: err.message };
    } finally {
      testingDb = false;
    }
  }

  async function saveRetention() {
    savingRetention = true;
    retentionMessage = null;

    try {
      const res = await fetch(`${API_BASE}/settings/retention`, {
        method: 'PUT',
        headers: getHeaders(),
        body: JSON.stringify({ days: retentionDays })
      });

      const data = await res.json();
      if (res.ok) {
        retentionMessage = { success: true, text: data.message };
        fetchRetentionStats();
      } else {
        retentionMessage = { success: false, text: data.error };
      }
    } catch (err) {
      retentionMessage = { success: false, text: err.message };
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
    <div class="loading-state">Loading configuration...</div>
  {:else}
    <!-- ClickHouse Connection -->
    <div class="settings-group">
      <div class="group-header">
        <span class="group-title">ClickHouse Connection</span>
        {#if serverSettings?.clickhouse?.host?.from_env}
          <span class="env-badge">From Environment</span>
        {/if}
      </div>

      <div class="form-grid">
        <div class="form-field">
          <label for="db-host">Host</label>
          <input
            id="db-host"
            type="text"
            bind:value={dbForm.host}
            placeholder="localhost"
          />
        </div>

        <div class="form-field">
          <label for="db-port">Port</label>
          <input
            id="db-port"
            type="number"
            bind:value={dbForm.port}
            placeholder="8123"
          />
        </div>

        <div class="form-field">
          <label for="db-database">Database</label>
          <input
            id="db-database"
            type="text"
            bind:value={dbForm.database}
            placeholder="purl"
          />
        </div>

        <div class="form-field">
          <label for="db-user">User</label>
          <input
            id="db-user"
            type="text"
            bind:value={dbForm.user}
            placeholder="default"
          />
        </div>

        <div class="form-field full-width">
          <label for="db-password">Password</label>
          <input
            id="db-password"
            type="password"
            bind:value={dbForm.password}
            placeholder={serverSettings?.clickhouse?.password_set?.value ? '********' : 'Enter password'}
          />
          {#if serverSettings?.clickhouse?.password_set?.value && !dbForm.password}
            <span class="field-hint">Password is already set. Leave empty to keep current.</span>
          {/if}
        </div>
      </div>

      <div class="form-actions">
        <button class="test-btn" on:click={testDbConnection} disabled={testingDb}>
          {testingDb ? 'Testing...' : 'Test Connection'}
        </button>
        <button class="save-btn" on:click={saveDbSettings} disabled={savingDb}>
          {savingDb ? 'Saving...' : 'Save Settings'}
        </button>
      </div>

      {#if dbTestResult}
        <div class="result-box" class:success={dbTestResult.success}>
          {#if dbTestResult.success}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="20 6 9 17 4 12"/>
            </svg>
            {dbTestResult.message}
          {:else}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>
            </svg>
            {dbTestResult.error}
          {/if}
        </div>
      {/if}

      {#if dbMessage}
        <div class="result-box" class:success={dbMessage.success}>
          {dbMessage.text}
        </div>
      {/if}
    </div>

    <!-- Retention Settings -->
    <div class="settings-group" style="margin-top: 24px;">
      <div class="group-header">
        <span class="group-title">Data Retention</span>
        {#if serverSettings?.retention?.days?.from_env}
          <span class="env-badge">From Environment</span>
        {/if}
      </div>

      <div class="setting-item">
        <div class="setting-info">
          <label for="retention-days">Retention Period</label>
          <span class="setting-hint">How long to keep log data (ClickHouse TTL)</span>
        </div>
        <div class="retention-control">
          <input
            id="retention-days"
            type="number"
            min="1"
            max="365"
            bind:value={retentionDays}
          />
          <span class="unit">days</span>
          <button class="save-btn" on:click={saveRetention} disabled={savingRetention}>
            {savingRetention ? 'Saving...' : 'Apply'}
          </button>
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
            <span class="stat-value">{retentionStats.total_logs?.toLocaleString() || 0}</span>
            <span class="stat-label">Total Logs</span>
          </div>
          <div class="stat-card">
            <span class="stat-value">{retentionStats.db_size_mb || 0} MB</span>
            <span class="stat-label">Database Size</span>
          </div>
          <div class="stat-card">
            <span class="stat-value">{retentionStats.oldest_log ? new Date(retentionStats.oldest_log).toLocaleDateString() : 'N/A'}</span>
            <span class="stat-label">Oldest Log</span>
          </div>
          <div class="stat-card">
            <span class="stat-value">{retentionStats.newest_log ? new Date(retentionStats.newest_log).toLocaleDateString() : 'N/A'}</span>
            <span class="stat-label">Newest Log</span>
          </div>
        </div>
      {/if}
    </div>
  {/if}
</section>

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
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  .settings-group {
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #21262d);
    border-radius: 8px;
    overflow: hidden;
  }

  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    background: rgba(33, 38, 45, 0.3);
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .group-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .env-badge {
    font-size: 0.6875rem;
    font-weight: 500;
    color: var(--color-warning, #d29922);
    background: rgba(210, 153, 34, 0.15);
    padding: 2px 8px;
    border-radius: 10px;
  }

  .form-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    padding: 16px;
  }

  .form-field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .form-field.full-width {
    grid-column: 1 / -1;
  }

  .form-field label {
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
  }

  .form-field input {
    padding: 8px 12px;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-primary, #c9d1d9);
    font-size: 0.875rem;
  }

  .form-field input:focus {
    outline: none;
    border-color: var(--color-primary, #58a6ff);
  }

  .field-hint {
    font-size: 0.6875rem;
    color: var(--text-secondary, #8b949e);
  }

  .form-actions {
    display: flex;
    gap: 8px;
    padding: 12px 16px;
    background: rgba(33, 38, 45, 0.3);
    border-top: 1px solid var(--border-color, #21262d);
  }

  .result-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    font-size: 0.8125rem;
    color: var(--color-error, #f85149);
    background: rgba(248, 81, 73, 0.1);
    border-top: 1px solid var(--border-color, #21262d);
  }

  .result-box.success {
    color: var(--color-success, #3fb950);
    background: rgba(63, 185, 80, 0.1);
  }

  .save-btn, .test-btn {
    padding: 8px 16px;
    border-radius: 6px;
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .save-btn {
    background: var(--color-success, #238636);
    border: 1px solid var(--color-success, #238636);
    color: #fff;
  }

  .save-btn:hover:not(:disabled) {
    background: #2ea043;
  }

  .save-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .test-btn {
    background: transparent;
    border: 1px solid var(--border-color, #30363d);
    color: var(--text-primary, #c9d1d9);
  }

  .test-btn:hover:not(:disabled) {
    background: var(--bg-tertiary, #21262d);
    border-color: var(--text-secondary, #8b949e);
  }

  .test-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .setting-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .setting-item:last-child {
    border-bottom: none;
  }

  .setting-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .setting-info label {
    font-size: 0.875rem;
    color: var(--text-primary, #c9d1d9);
  }

  .setting-hint {
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
  }

  .retention-control {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .retention-control input {
    width: 80px;
    padding: 8px 12px;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-primary, #c9d1d9);
    text-align: center;
  }

  .retention-control .unit {
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
  }

  .stats-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
    padding: 16px;
    background: var(--bg-primary, #0d1117);
    border-top: 1px solid var(--border-color, #21262d);
  }

  .stat-card {
    text-align: center;
    padding: 12px 8px;
    background: var(--bg-secondary, #161b22);
    border-radius: 6px;
  }

  .stat-value {
    display: block;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
  }

  .stat-label {
    display: block;
    font-size: 0.6875rem;
    color: var(--text-secondary, #8b949e);
    margin-top: 4px;
  }

  .loading-state {
    padding: 40px;
    text-align: center;
    color: var(--text-secondary, #8b949e);
  }
</style>
