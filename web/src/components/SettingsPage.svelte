<script>
  import { onMount } from 'svelte';

  let settings = {
    theme: 'dark',
    refreshInterval: 30,
    defaultTimeRange: '15m',
    maxResults: 500,
    showHost: true,
    showRaw: false,
    compactMode: false,
    lineWrap: true,
    timestampFormat: 'relative',
    logLevel: 'all',
    fontSize: 'medium',
    highlightErrors: true,
    autoScroll: true,
    soundAlerts: false,
    keyboardShortcuts: true,
  };

  let activeSection = 'database';
  let saved = false;
  let systemInfo = null;

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

  // Notifications form
  let notifications = {
    telegram: { enabled: false, bot_token: '', chat_id: '' },
    slack: { enabled: false, webhook_url: '', channel: '' },
    webhook: { enabled: false, url: '', auth_token: '' }
  };
  let savingNotification = null;
  let notificationMessage = {};
  let testingNotification = null;
  let notificationTestResult = {};

  const API_BASE = '/api';

  const sections = [
    { id: 'database', label: 'Database', icon: 'server' },
    { id: 'notifications', label: 'Notifications', icon: 'bell' },
    { id: 'display', label: 'Display', icon: 'monitor' },
    { id: 'logs', label: 'Log Viewer', icon: 'file-text' },
    { id: 'shortcuts', label: 'Shortcuts', icon: 'keyboard' },
    { id: 'data', label: 'Data', icon: 'database' },
    { id: 'about', label: 'About', icon: 'info' },
  ];

  const timeRangeOptions = [
    { value: '5m', label: '5 minutes' },
    { value: '15m', label: '15 minutes' },
    { value: '1h', label: '1 hour' },
    { value: '24h', label: '24 hours' },
    { value: '7d', label: '7 days' },
  ];

  const shortcuts = [
    { key: '/', action: 'Focus search' },
    { key: 'Escape', action: 'Clear search / Close modal' },
    { key: 'r', action: 'Refresh logs' },
    { key: 'l', action: 'Toggle live mode' },
    { key: 'e', action: 'Export logs' },
    { key: 's', action: 'Open saved searches' },
    { key: 'a', action: 'Open alerts' },
    { key: ',', action: 'Open settings' },
    { key: '1-5', action: 'Switch time range' },
    { key: '?', action: 'Show shortcuts help' },
  ];

  onMount(() => {
    loadSettings();
    fetchSystemInfo();
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

        // Populate database form
        dbForm.host = serverSettings.clickhouse?.host?.value || 'localhost';
        dbForm.port = serverSettings.clickhouse?.port?.value || 8123;
        dbForm.database = serverSettings.clickhouse?.database?.value || 'purl';
        dbForm.user = serverSettings.clickhouse?.user?.value || 'default';
        dbForm.password = '';

        // Populate retention
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

  async function saveNotification(type) {
    savingNotification = type;
    notificationMessage[type] = null;

    try {
      const res = await fetch(`${API_BASE}/settings/notifications/${type}`, {
        method: 'PUT',
        headers: getHeaders(),
        body: JSON.stringify(notifications[type])
      });

      const data = await res.json();
      if (res.ok) {
        notificationMessage[type] = { success: true, text: data.message };
      } else {
        notificationMessage[type] = { success: false, text: data.error };
      }
    } catch (err) {
      notificationMessage[type] = { success: false, text: err.message };
    } finally {
      savingNotification = null;
    }
  }

  async function testNotification(type) {
    testingNotification = type;
    notificationTestResult[type] = null;

    try {
      const res = await fetch(`${API_BASE}/settings/notifications/${type}/test`, {
        method: 'POST',
        headers: getHeaders()
      });

      notificationTestResult[type] = await res.json();
    } catch (err) {
      notificationTestResult[type] = { success: false, error: err.message };
    } finally {
      testingNotification = null;
    }
  }

  function loadSettings() {
    const saved = localStorage.getItem('purl_settings');
    if (saved) {
      settings = { ...settings, ...JSON.parse(saved) };
    }
  }

  function saveSettings() {
    localStorage.setItem('purl_settings', JSON.stringify(settings));
    saved = true;
    setTimeout(() => saved = false, 2000);
  }

  async function fetchSystemInfo() {
    try {
      const res = await fetch(`${API_BASE}/health`);
      if (res.ok) {
        systemInfo = await res.json();
      }
    } catch {
      // Ignore
    }
  }

  async function clearCache() {
    try {
      await fetch(`${API_BASE}/cache`, { method: 'DELETE', headers: getHeaders() });
      alert('Cache cleared successfully');
    } catch {
      alert('Failed to clear cache');
    }
  }

  function formatUptime(seconds) {
    if (!seconds) return '0s';
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    const parts = [];
    if (days > 0) parts.push(`${days}d`);
    if (hours > 0) parts.push(`${hours}h`);
    if (mins > 0) parts.push(`${mins}m`);
    return parts.join(' ') || '< 1m';
  }

  function isFromEnv(section, field) {
    if (!serverSettings) return false;
    return serverSettings[section]?.[field]?.from_env || false;
  }
</script>

<div class="settings-page">
  <aside class="settings-nav">
    <h2>Settings</h2>
    <nav>
      {#each sections as section}
        <button
          class="nav-item"
          class:active={activeSection === section.id}
          on:click={() => activeSection = section.id}
        >
          {#if section.icon === 'server'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/>
            </svg>
          {:else if section.icon === 'monitor'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>
            </svg>
          {:else if section.icon === 'file-text'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/>
            </svg>
          {:else if section.icon === 'bell'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>
            </svg>
          {:else if section.icon === 'keyboard'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="4" width="20" height="16" rx="2"/><path d="M6 8h.001M10 8h.001M14 8h.001M18 8h.001M8 12h.001M12 12h.001M16 12h.001M7 16h10"/>
            </svg>
          {:else if section.icon === 'database'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/>
            </svg>
          {:else if section.icon === 'info'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>
            </svg>
          {/if}
          {section.label}
        </button>
      {/each}
    </nav>
  </aside>

  <main class="settings-content">
    {#if activeSection === 'database'}
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
                  disabled={isFromEnv('clickhouse', 'host')}
                />
                {#if isFromEnv('clickhouse', 'host')}
                  <span class="field-hint env">Set via PURL_CLICKHOUSE_HOST</span>
                {/if}
              </div>

              <div class="form-field">
                <label for="db-port">Port</label>
                <input
                  id="db-port"
                  type="number"
                  bind:value={dbForm.port}
                  placeholder="8123"
                  disabled={isFromEnv('clickhouse', 'port')}
                />
              </div>

              <div class="form-field">
                <label for="db-database">Database</label>
                <input
                  id="db-database"
                  type="text"
                  bind:value={dbForm.database}
                  placeholder="purl"
                  disabled={isFromEnv('clickhouse', 'database')}
                />
              </div>

              <div class="form-field">
                <label for="db-user">User</label>
                <input
                  id="db-user"
                  type="text"
                  bind:value={dbForm.user}
                  placeholder="default"
                  disabled={isFromEnv('clickhouse', 'user')}
                />
              </div>

              <div class="form-field full-width">
                <label for="db-password">Password</label>
                <input
                  id="db-password"
                  type="password"
                  bind:value={dbForm.password}
                  placeholder={serverSettings?.clickhouse?.password_set?.value ? '********' : 'Enter password'}
                  disabled={isFromEnv('clickhouse', 'password')}
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
              <button class="save-btn" on:click={saveDbSettings} disabled={savingDb || isFromEnv('clickhouse', 'host')}>
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
                  disabled={serverSettings?.retention?.days?.from_env}
                />
                <span class="unit">days</span>
                <button class="save-btn" on:click={saveRetention} disabled={savingRetention || serverSettings?.retention?.days?.from_env}>
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
    {/if}

    {#if activeSection === 'notifications'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Alert Notifications</h3>
          <p>Configure notification channels for alerts</p>
        </div>

        <!-- Telegram -->
        <div class="notification-card">
          <div class="notification-header">
            <div class="notification-icon telegram">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8c-.15 1.58-.8 5.42-1.13 7.19-.14.75-.42 1-.68 1.03-.58.05-1.02-.38-1.58-.75-.88-.58-1.38-.94-2.23-1.5-.99-.65-.35-1.01.22-1.59.15-.15 2.71-2.48 2.76-2.69a.2.2 0 00-.05-.18c-.06-.05-.14-.03-.21-.02-.09.02-1.49.95-4.22 2.79-.4.27-.76.41-1.08.4-.36-.01-1.04-.2-1.55-.37-.63-.2-1.12-.31-1.08-.66.02-.18.27-.36.74-.55 2.92-1.27 4.86-2.11 5.83-2.51 2.78-1.16 3.35-1.36 3.73-1.36.08 0 .27.02.39.12.1.08.13.19.14.27-.01.06.01.24 0 .38z"/>
              </svg>
            </div>
            <div class="notification-info">
              <h4>Telegram</h4>
              <p>Receive alerts via Telegram bot</p>
            </div>
            {#if serverSettings?.notifications?.telegram?.from_env}
              <span class="env-badge">From Environment</span>
            {/if}
          </div>

          <div class="notification-form">
            <div class="form-field">
              <label>Bot Token</label>
              <input
                type="password"
                bind:value={notifications.telegram.bot_token}
                placeholder="123456:ABC-DEF..."
                disabled={serverSettings?.notifications?.telegram?.from_env}
              />
            </div>
            <div class="form-field">
              <label>Chat ID</label>
              <input
                type="text"
                bind:value={notifications.telegram.chat_id}
                placeholder="-1001234567890"
                disabled={serverSettings?.notifications?.telegram?.from_env}
              />
            </div>
            <div class="form-actions">
              <button class="test-btn" on:click={() => testNotification('telegram')} disabled={testingNotification === 'telegram'}>
                {testingNotification === 'telegram' ? 'Testing...' : 'Test'}
              </button>
              <button class="save-btn" on:click={() => saveNotification('telegram')} disabled={savingNotification === 'telegram' || serverSettings?.notifications?.telegram?.from_env}>
                {savingNotification === 'telegram' ? 'Saving...' : 'Save'}
              </button>
            </div>
            {#if notificationTestResult.telegram}
              <div class="result-box" class:success={notificationTestResult.telegram.success}>
                {notificationTestResult.telegram.success ? notificationTestResult.telegram.message : notificationTestResult.telegram.error}
              </div>
            {/if}
            {#if notificationMessage.telegram}
              <div class="result-box" class:success={notificationMessage.telegram.success}>
                {notificationMessage.telegram.text}
              </div>
            {/if}
          </div>
        </div>

        <!-- Slack -->
        <div class="notification-card">
          <div class="notification-header">
            <div class="notification-icon slack">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
                <path d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z"/>
              </svg>
            </div>
            <div class="notification-info">
              <h4>Slack</h4>
              <p>Post alerts to Slack channel</p>
            </div>
            {#if serverSettings?.notifications?.slack?.from_env}
              <span class="env-badge">From Environment</span>
            {/if}
          </div>

          <div class="notification-form">
            <div class="form-field">
              <label>Webhook URL</label>
              <input
                type="password"
                bind:value={notifications.slack.webhook_url}
                placeholder="https://hooks.slack.com/services/..."
                disabled={serverSettings?.notifications?.slack?.from_env}
              />
            </div>
            <div class="form-field">
              <label>Channel (optional)</label>
              <input
                type="text"
                bind:value={notifications.slack.channel}
                placeholder="#alerts"
                disabled={serverSettings?.notifications?.slack?.from_env}
              />
            </div>
            <div class="form-actions">
              <button class="test-btn" on:click={() => testNotification('slack')} disabled={testingNotification === 'slack'}>
                {testingNotification === 'slack' ? 'Testing...' : 'Test'}
              </button>
              <button class="save-btn" on:click={() => saveNotification('slack')} disabled={savingNotification === 'slack' || serverSettings?.notifications?.slack?.from_env}>
                {savingNotification === 'slack' ? 'Saving...' : 'Save'}
              </button>
            </div>
            {#if notificationTestResult.slack}
              <div class="result-box" class:success={notificationTestResult.slack.success}>
                {notificationTestResult.slack.success ? notificationTestResult.slack.message : notificationTestResult.slack.error}
              </div>
            {/if}
            {#if notificationMessage.slack}
              <div class="result-box" class:success={notificationMessage.slack.success}>
                {notificationMessage.slack.text}
              </div>
            {/if}
          </div>
        </div>

        <!-- Webhook -->
        <div class="notification-card">
          <div class="notification-header">
            <div class="notification-icon webhook">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>
                <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>
              </svg>
            </div>
            <div class="notification-info">
              <h4>Webhook</h4>
              <p>Send to custom HTTP endpoint</p>
            </div>
            {#if serverSettings?.notifications?.webhook?.from_env}
              <span class="env-badge">From Environment</span>
            {/if}
          </div>

          <div class="notification-form">
            <div class="form-field">
              <label>Webhook URL</label>
              <input
                type="text"
                bind:value={notifications.webhook.url}
                placeholder="https://your-server.com/webhook"
                disabled={serverSettings?.notifications?.webhook?.from_env}
              />
            </div>
            <div class="form-field">
              <label>Auth Token (optional)</label>
              <input
                type="password"
                bind:value={notifications.webhook.auth_token}
                placeholder="Bearer token"
                disabled={serverSettings?.notifications?.webhook?.from_env}
              />
            </div>
            <div class="form-actions">
              <button class="test-btn" on:click={() => testNotification('webhook')} disabled={testingNotification === 'webhook'}>
                {testingNotification === 'webhook' ? 'Testing...' : 'Test'}
              </button>
              <button class="save-btn" on:click={() => saveNotification('webhook')} disabled={savingNotification === 'webhook' || serverSettings?.notifications?.webhook?.from_env}>
                {savingNotification === 'webhook' ? 'Saving...' : 'Save'}
              </button>
            </div>
            {#if notificationTestResult.webhook}
              <div class="result-box" class:success={notificationTestResult.webhook.success}>
                {notificationTestResult.webhook.success ? notificationTestResult.webhook.message : notificationTestResult.webhook.error}
              </div>
            {/if}
            {#if notificationMessage.webhook}
              <div class="result-box" class:success={notificationMessage.webhook.success}>
                {notificationMessage.webhook.text}
              </div>
            {/if}
          </div>
        </div>

        <div class="auth-info">
          <h4>Settings Storage</h4>
          <p>Notification settings are saved to <code>/app/config/settings.json</code> on the server.</p>
          <p>Environment variables take precedence over UI settings and cannot be modified here.</p>
        </div>
      </section>
    {/if}

    {#if activeSection === 'display'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Display Settings</h3>
          <p>Customize the appearance of your dashboard</p>
        </div>

        <div class="settings-group">
          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Default Time Range</span>
              <span class="setting-hint">Initial time range when opening logs</span>
            </div>
            <select bind:value={settings.defaultTimeRange} on:change={saveSettings}>
              {#each timeRangeOptions as option}
                <option value={option.value}>{option.label}</option>
              {/each}
            </select>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Refresh Interval</span>
              <span class="setting-hint">Auto-refresh interval in seconds (0 = disabled)</span>
            </div>
            <input type="number" min="0" max="300" bind:value={settings.refreshInterval} on:change={saveSettings} />
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Max Results</span>
              <span class="setting-hint">Maximum number of logs to display</span>
            </div>
            <input type="number" min="50" max="5000" bind:value={settings.maxResults} on:change={saveSettings} />
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Compact Mode</span>
              <span class="setting-hint">Reduce spacing in log list</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.compactMode} on:change={saveSettings} />
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Line Wrap</span>
              <span class="setting-hint">Wrap long log messages</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.lineWrap} on:change={saveSettings} />
              <span class="toggle-slider"></span>
            </label>
          </div>
        </div>
      </section>
    {/if}

    {#if activeSection === 'logs'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Log Viewer Settings</h3>
          <p>Configure log display preferences</p>
        </div>

        <div class="settings-group">
          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Show Host Column</span>
              <span class="setting-hint">Display host information in log list</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.showHost} on:change={saveSettings} />
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Show Raw Messages</span>
              <span class="setting-hint">Display raw log data by default</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.showRaw} on:change={saveSettings} />
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Highlight Errors</span>
              <span class="setting-hint">Highlight ERROR and FATAL logs</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.highlightErrors} on:change={saveSettings} />
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Auto Scroll</span>
              <span class="setting-hint">Auto-scroll to new logs in live mode</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.autoScroll} on:change={saveSettings} />
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Timestamp Format</span>
              <span class="setting-hint">How to display timestamps</span>
            </div>
            <select bind:value={settings.timestampFormat} on:change={saveSettings}>
              <option value="relative">Relative (5 min ago)</option>
              <option value="absolute">Absolute (12:34:56)</option>
              <option value="iso">ISO 8601</option>
            </select>
          </div>
        </div>
      </section>
    {/if}

    {#if activeSection === 'shortcuts'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Keyboard Shortcuts</h3>
          <p>Quick actions for power users</p>
        </div>

        <div class="settings-group">
          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Enable Keyboard Shortcuts</span>
              <span class="setting-hint">Turn keyboard shortcuts on/off</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.keyboardShortcuts} on:change={saveSettings} />
              <span class="toggle-slider"></span>
            </label>
          </div>
        </div>

        <div class="shortcuts-list">
          {#each shortcuts as shortcut}
            <div class="shortcut-item">
              <kbd>{shortcut.key}</kbd>
              <span>{shortcut.action}</span>
            </div>
          {/each}
        </div>
      </section>
    {/if}

    {#if activeSection === 'data'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Data Management</h3>
          <p>Manage cache and stored data</p>
        </div>

        <div class="settings-group">
          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Clear Query Cache</span>
              <span class="setting-hint">Clear server-side query cache</span>
            </div>
            <button class="danger-btn" on:click={clearCache}>Clear Cache</button>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Clear Local Storage</span>
              <span class="setting-hint">Reset all client-side settings</span>
            </div>
            <button class="danger-btn" on:click={() => { localStorage.clear(); location.reload(); }}>Reset</button>
          </div>
        </div>
      </section>
    {/if}

    {#if activeSection === 'about'}
      <section class="settings-section">
        <div class="section-header">
          <h3>About Purl</h3>
          <p>Log aggregation and analysis platform</p>
        </div>

        <div class="about-card">
          <div class="about-logo">
            <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="#58a6ff" stroke-width="1.5">
              <rect x="3" y="3" width="18" height="18" rx="2"/>
              <line x1="7" y1="8" x2="17" y2="8"/>
              <line x1="7" y1="12" x2="14" y2="12"/>
              <line x1="7" y1="16" x2="11" y2="16"/>
            </svg>
          </div>

          <h2>Purl</h2>
          <p class="about-tagline">Fast, Modern Log Aggregation</p>
          <p class="about-version">Version 1.0.0</p>

          <div class="tech-stack">
            <span class="tech-badge">Perl</span>
            <span class="tech-badge">ClickHouse</span>
            <span class="tech-badge">Svelte</span>
            <span class="tech-badge">Vector</span>
          </div>

          {#if systemInfo}
            <div class="system-status">
              <div class="status-row">
                <span>Status</span>
                <span class="status-badge" class:ok={systemInfo.status === 'ok'}>{systemInfo.status?.toUpperCase()}</span>
              </div>
              <div class="status-row">
                <span>ClickHouse</span>
                <span class="status-value">{systemInfo.clickhouse}</span>
              </div>
              <div class="status-row">
                <span>Uptime</span>
                <span class="status-value">{formatUptime(systemInfo.uptime_secs)}</span>
              </div>
            </div>
          {/if}

          <div class="about-links">
            <a href="https://github.com/ismoilovdevml/purl" target="_blank" rel="noopener" class="about-link">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
              </svg>
              GitHub
            </a>
            <a href="/api/metrics" target="_blank" class="about-link">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M18 20V10M12 20V4M6 20v-6"/>
              </svg>
              Metrics
            </a>
          </div>
        </div>
      </section>
    {/if}

    {#if saved}
      <div class="save-toast">Settings saved!</div>
    {/if}
  </main>
</div>

<style>
  .settings-page {
    display: flex;
    min-height: 100%;
    background: #0d1117;
    color: #c9d1d9;
  }

  .settings-nav {
    width: 220px;
    background: #161b22;
    border-right: 1px solid #21262d;
    padding: 20px 0;
    flex-shrink: 0;
  }

  .settings-nav h2 {
    font-size: 1rem;
    font-weight: 600;
    padding: 0 16px 16px;
    margin: 0;
    border-bottom: 1px solid #21262d;
    color: #f0f6fc;
  }

  .settings-nav nav {
    padding: 8px 0;
  }

  .nav-item {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 10px 16px;
    background: none;
    border: none;
    color: #8b949e;
    font-size: 0.875rem;
    cursor: pointer;
    transition: all 0.15s;
    text-align: left;
  }

  .nav-item:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .nav-item.active {
    background: #1f6feb20;
    color: #58a6ff;
    border-left: 2px solid #58a6ff;
  }

  .settings-content {
    flex: 1;
    padding: 24px 32px;
    overflow-y: auto;
  }

  .settings-section {
    max-width: 800px;
  }

  .section-header {
    margin-bottom: 24px;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: #8b949e;
    margin: 0;
  }

  .settings-group {
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 8px;
    overflow: hidden;
  }

  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    background: #21262d30;
    border-bottom: 1px solid #21262d;
  }

  .group-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .env-badge {
    font-size: 0.6875rem;
    font-weight: 500;
    color: #d29922;
    background: #d2992220;
    padding: 2px 8px;
    border-radius: 10px;
  }

  .setting-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid #21262d;
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
    color: #c9d1d9;
  }

  .setting-hint {
    font-size: 0.75rem;
    color: #8b949e;
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
    color: #8b949e;
  }

  .form-field input {
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.875rem;
  }

  .form-field input:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .form-field input:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .field-hint {
    font-size: 0.6875rem;
    color: #8b949e;
  }

  .field-hint.env {
    color: #d29922;
  }

  .form-actions {
    display: flex;
    gap: 8px;
    padding: 12px 16px;
    background: #21262d30;
    border-top: 1px solid #21262d;
  }

  .result-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    font-size: 0.8125rem;
    color: #f85149;
    background: #f8514915;
    border-top: 1px solid #21262d;
  }

  .result-box.success {
    color: #3fb950;
    background: #3fb95015;
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
    background: #238636;
    border: 1px solid #238636;
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
    border: 1px solid #30363d;
    color: #c9d1d9;
  }

  .test-btn:hover:not(:disabled) {
    background: #21262d;
    border-color: #8b949e;
  }

  .test-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .danger-btn {
    padding: 8px 16px;
    background: #21262d;
    border: 1px solid #f85149;
    border-radius: 6px;
    color: #f85149;
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
  }

  .danger-btn:hover {
    background: #f8514920;
  }

  .retention-control {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .retention-control input {
    width: 80px;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    text-align: center;
  }

  .retention-control .unit {
    font-size: 0.8125rem;
    color: #8b949e;
  }

  .stats-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
    padding: 16px;
    background: #0d1117;
    border-top: 1px solid #21262d;
  }

  .stat-card {
    text-align: center;
    padding: 12px 8px;
    background: #161b22;
    border-radius: 6px;
  }

  .stat-value {
    display: block;
    font-size: 0.9375rem;
    font-weight: 600;
    color: #f0f6fc;
    font-family: 'SF Mono', Monaco, monospace;
  }

  .stat-label {
    display: block;
    font-size: 0.6875rem;
    color: #8b949e;
    margin-top: 4px;
  }

  .notification-card {
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 8px;
    margin-bottom: 16px;
    overflow: hidden;
  }

  .notification-header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 16px;
    border-bottom: 1px solid #21262d;
  }

  .notification-icon {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .notification-icon.telegram {
    background: #0088cc20;
    color: #0088cc;
  }

  .notification-icon.slack {
    background: #4a154b20;
    color: #e01e5a;
  }

  .notification-icon.webhook {
    background: #58a6ff20;
    color: #58a6ff;
  }

  .notification-info {
    flex: 1;
  }

  .notification-info h4 {
    margin: 0;
    font-size: 0.9375rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .notification-info p {
    margin: 2px 0 0;
    font-size: 0.75rem;
    color: #8b949e;
  }

  .notification-form {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .notification-form .form-field {
    flex-direction: row;
    align-items: center;
    gap: 12px;
  }

  .notification-form .form-field label {
    width: 120px;
    flex-shrink: 0;
  }

  .notification-form .form-field input {
    flex: 1;
  }

  .notification-form .form-actions {
    padding: 0;
    background: none;
    border: none;
    justify-content: flex-end;
  }

  .notification-form .result-box {
    border: none;
    border-radius: 6px;
    margin: 0;
  }

  .loading-state {
    padding: 40px;
    text-align: center;
    color: #8b949e;
  }

  .auth-info {
    margin-top: 24px;
    padding: 16px;
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 8px;
  }

  .auth-info h4 {
    margin: 0 0 8px;
    font-size: 0.875rem;
    color: #f0f6fc;
  }

  .auth-info p {
    margin: 8px 0;
    font-size: 0.8125rem;
    color: #8b949e;
  }

  .auth-info code {
    background: #21262d;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 0.8125rem;
    color: #f85149;
  }

  .auth-info pre {
    margin: 12px 0;
    padding: 12px;
    background: #0d1117;
    border-radius: 6px;
    overflow-x: auto;
  }

  .auth-info pre code {
    background: none;
    padding: 0;
    color: #7ee787;
  }

  .api-key-control {
    display: flex;
    gap: 8px;
  }

  .api-key-control input {
    width: 300px;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
  }

  .api-key-control input:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .toggle {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
  }

  .toggle input {
    opacity: 0;
    width: 0;
    height: 0;
  }

  .toggle-slider {
    position: absolute;
    cursor: pointer;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: #21262d;
    border-radius: 12px;
    transition: 0.2s;
  }

  .toggle-slider:before {
    position: absolute;
    content: "";
    height: 18px;
    width: 18px;
    left: 3px;
    bottom: 3px;
    background: #8b949e;
    border-radius: 50%;
    transition: 0.2s;
  }

  .toggle input:checked + .toggle-slider {
    background: #238636;
  }

  .toggle input:checked + .toggle-slider:before {
    transform: translateX(20px);
    background: #fff;
  }

  select {
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.875rem;
  }

  input[type="number"] {
    width: 80px;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    text-align: center;
  }

  .shortcuts-list {
    margin-top: 16px;
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 8px;
    overflow: hidden;
  }

  .shortcut-item {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 10px 16px;
    border-bottom: 1px solid #21262d;
  }

  .shortcut-item:last-child {
    border-bottom: none;
  }

  .shortcut-item kbd {
    min-width: 50px;
    padding: 4px 8px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    font-family: 'SF Mono', Monaco, monospace;
    font-size: 0.75rem;
    color: #f0f6fc;
    text-align: center;
  }

  .shortcut-item span {
    font-size: 0.875rem;
    color: #8b949e;
  }

  .about-card {
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 8px;
    padding: 32px;
    text-align: center;
  }

  .about-logo {
    margin-bottom: 16px;
  }

  .about-card h2 {
    margin: 0;
    font-size: 1.5rem;
    font-weight: 700;
    color: #f0f6fc;
  }

  .about-tagline {
    margin: 4px 0 0;
    font-size: 0.9375rem;
    color: #8b949e;
  }

  .about-version {
    margin: 8px 0 16px;
    font-size: 0.8125rem;
    color: #6e7681;
    font-family: 'SF Mono', Monaco, monospace;
  }

  .tech-stack {
    display: flex;
    justify-content: center;
    gap: 8px;
    margin-bottom: 24px;
  }

  .tech-badge {
    padding: 4px 12px;
    background: #21262d;
    border-radius: 16px;
    font-size: 0.75rem;
    color: #c9d1d9;
  }

  .system-status {
    background: #0d1117;
    border-radius: 8px;
    padding: 12px 16px;
    margin-bottom: 24px;
    text-align: left;
  }

  .status-row {
    display: flex;
    justify-content: space-between;
    padding: 6px 0;
    font-size: 0.8125rem;
  }

  .status-row span:first-child {
    color: #8b949e;
  }

  .status-badge {
    padding: 2px 8px;
    border-radius: 10px;
    font-size: 0.6875rem;
    font-weight: 600;
    background: #f8514920;
    color: #f85149;
  }

  .status-badge.ok {
    background: #3fb95020;
    color: #3fb950;
  }

  .status-value {
    color: #f0f6fc;
    font-family: 'SF Mono', Monaco, monospace;
  }

  .about-links {
    display: flex;
    justify-content: center;
    gap: 12px;
  }

  .about-link {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 20px;
    background: #21262d;
    border-radius: 6px;
    color: #c9d1d9;
    text-decoration: none;
    font-size: 0.875rem;
    transition: background 0.15s;
  }

  .about-link:hover {
    background: #30363d;
  }

  .save-toast {
    position: fixed;
    bottom: 24px;
    right: 24px;
    padding: 12px 20px;
    background: #238636;
    border-radius: 6px;
    color: #fff;
    font-size: 0.875rem;
    animation: slideIn 0.2s ease;
  }

  @keyframes slideIn {
    from {
      transform: translateY(20px);
      opacity: 0;
    }
    to {
      transform: translateY(0);
      opacity: 1;
    }
  }
</style>
