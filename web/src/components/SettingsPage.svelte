<script>
  import { onMount } from 'svelte';
  import { setApiKey, apiKey as apiKeyStore } from '../stores/logs.js';

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
    notifications: {
      telegram: { configured: false },
      slack: { configured: false },
      webhook: { configured: false }
    }
  };

  let apiKey = '';
  let activeSection = 'auth';
  let testingNotification = null;
  let testResult = null;
  let saved = false;
  let systemInfo = null;

  // Server config state
  let serverConfig = null;
  let retentionDays = 30;
  let retentionStats = null;
  let savingRetention = false;
  let retentionMessage = null;

  // ClickHouse test state
  let testingClickHouse = false;
  let clickHouseTestResult = null;

  const API_BASE = '/api';

  const sections = [
    { id: 'auth', label: 'Authentication', icon: 'key' },
    { id: 'database', label: 'Database', icon: 'server' },
    { id: 'display', label: 'Display', icon: 'monitor' },
    { id: 'logs', label: 'Log Viewer', icon: 'file-text' },
    { id: 'notifications', label: 'Notifications', icon: 'bell' },
    { id: 'keyboard', label: 'Shortcuts', icon: 'keyboard' },
    { id: 'data', label: 'Data', icon: 'database' },
    { id: 'about', label: 'About', icon: 'info' },
  ];

  const timeRangeOptions = [
    { value: '5m', label: '5 minutes' },
    { value: '15m', label: '15 minutes' },
    { value: '30m', label: '30 minutes' },
    { value: '1h', label: '1 hour' },
    { value: '4h', label: '4 hours' },
    { value: '12h', label: '12 hours' },
    { value: '24h', label: '24 hours' },
    { value: '7d', label: '7 days' },
  ];

  const refreshOptions = [
    { value: 0, label: 'Off' },
    { value: 5, label: '5 seconds' },
    { value: 10, label: '10 seconds' },
    { value: 30, label: '30 seconds' },
    { value: 60, label: '1 minute' },
    { value: 300, label: '5 minutes' },
  ];

  const fontSizeOptions = [
    { value: 'small', label: 'Small (12px)' },
    { value: 'medium', label: 'Medium (13px)' },
    { value: 'large', label: 'Large (14px)' },
  ];

  const timestampOptions = [
    { value: 'relative', label: 'Relative (2 min ago)' },
    { value: 'absolute', label: 'Absolute (10:30:45)' },
    { value: 'iso', label: 'ISO (2025-12-10T10:30:45Z)' },
  ];

  const shortcuts = [
    { key: '/', action: 'Focus search bar' },
    { key: 'Esc', action: 'Clear search / Close modal' },
    { key: 'R', action: 'Refresh logs' },
    { key: 'J / K', action: 'Navigate up/down' },
    { key: 'Enter', action: 'Expand selected log' },
    { key: 'C', action: 'Copy selected log' },
    { key: '1-5', action: 'Switch time range' },
    { key: '?', action: 'Show shortcuts help' },
  ];

  onMount(() => {
    loadSettings();
    apiKey = localStorage.getItem('purl_api_key') || '';
    checkNotificationStatus();
    fetchSystemInfo();
    fetchServerConfig();
    fetchRetentionStats();
  });

  async function fetchServerConfig() {
    try {
      const headers = {};
      const storedKey = localStorage.getItem('purl_api_key');
      if (storedKey) headers['X-API-Key'] = storedKey;

      const res = await fetch(`${API_BASE}/config`, { headers });
      if (res.ok) {
        serverConfig = await res.json();
        retentionDays = serverConfig.retention?.days || 30;
      }
    } catch {
      // Ignore
    }
  }

  async function fetchRetentionStats() {
    try {
      const headers = {};
      const storedKey = localStorage.getItem('purl_api_key');
      if (storedKey) headers['X-API-Key'] = storedKey;

      const res = await fetch(`${API_BASE}/config/retention`, { headers });
      if (res.ok) {
        retentionStats = await res.json();
        retentionDays = retentionStats.retention_days || 30;
      }
    } catch {
      // Ignore
    }
  }

  async function saveRetention() {
    savingRetention = true;
    retentionMessage = null;

    try {
      const headers = { 'Content-Type': 'application/json' };
      const storedKey = localStorage.getItem('purl_api_key');
      if (storedKey) headers['X-API-Key'] = storedKey;

      const res = await fetch(`${API_BASE}/config/retention`, {
        method: 'PUT',
        headers,
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

  async function testClickHouseConnection() {
    testingClickHouse = true;
    clickHouseTestResult = null;

    try {
      const headers = { 'Content-Type': 'application/json' };
      const storedKey = localStorage.getItem('purl_api_key');
      if (storedKey) headers['X-API-Key'] = storedKey;

      const res = await fetch(`${API_BASE}/config/test-clickhouse`, {
        method: 'POST',
        headers,
        body: JSON.stringify({})
      });

      clickHouseTestResult = await res.json();
    } catch (err) {
      clickHouseTestResult = { success: false, error: err.message };
    } finally {
      testingClickHouse = false;
    }
  }

  function saveApiKey() {
    setApiKey(apiKey);
    saved = true;
    setTimeout(() => saved = false, 2000);
  }

  function loadSettings() {
    const stored = localStorage.getItem('purl_settings');
    if (stored) {
      try {
        const parsed = JSON.parse(stored);
        settings = { ...settings, ...parsed };
      } catch {
        // Ignore
      }
    }
  }

  function saveSettings() {
    localStorage.setItem('purl_settings', JSON.stringify(settings));
    saved = true;
    setTimeout(() => saved = false, 2000);
    window.dispatchEvent(new CustomEvent('settings-changed', { detail: settings }));
  }

  async function checkNotificationStatus() {
    try {
      const res = await fetch(`${API_BASE}/analytics/notifiers`);
      if (res.ok) {
        const data = await res.json();
        settings.notifications.telegram.configured = !!data.notifiers?.telegram;
        settings.notifications.slack.configured = !!data.notifiers?.slack;
        settings.notifications.webhook.configured = !!data.notifiers?.webhook;
      }
    } catch {
      // Ignore
    }
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

  async function testNotification(type) {
    testingNotification = type;
    testResult = null;

    try {
      const res = await fetch(`${API_BASE}/alerts/test-notification?type=${type}`, {
        method: 'POST'
      });
      const data = await res.json();
      testResult = {
        type,
        success: data.success,
        message: data.success ? 'Test sent successfully!' : (data.error || 'Failed to send')
      };
    } catch (err) {
      testResult = { type, success: false, message: err.message };
    } finally {
      testingNotification = null;
    }
  }

  function clearCache() {
    if (confirm('Clear application cache? This will reset temporary data.')) {
      fetch(`${API_BASE}/cache`, { method: 'DELETE' });
      localStorage.removeItem('purl_search_history');
      alert('Cache cleared successfully');
    }
  }

  function clearAllData() {
    if (!confirm('Clear ALL local data? This includes settings, saved searches, and preferences.')) {
      return;
    }
    localStorage.clear();
    window.location.reload();
  }

  function exportSettings() {
    const data = {
      settings,
      columnConfig: localStorage.getItem('purl_column_config'),
      savedSearches: localStorage.getItem('purl_saved_searches'),
      searchHistory: localStorage.getItem('purl_search_history'),
      exportDate: new Date().toISOString(),
      version: '1.0.0'
    };

    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `purl-settings-${new Date().toISOString().split('T')[0]}.json`;
    a.click();
    URL.revokeObjectURL(url);
  }

  function importSettings(event) {
    const file = event.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (e) => {
      try {
        const data = JSON.parse(e.target?.result);
        if (data.settings) {
          settings = { ...settings, ...data.settings };
          saveSettings();
        }
        if (data.columnConfig) localStorage.setItem('purl_column_config', data.columnConfig);
        if (data.savedSearches) localStorage.setItem('purl_saved_searches', data.savedSearches);
        if (data.searchHistory) localStorage.setItem('purl_search_history', data.searchHistory);
        alert('Settings imported successfully!');
      } catch {
        alert('Failed to import: Invalid file format');
      }
    };
    reader.readAsText(file);
    event.target.value = '';
  }

  function resetToDefaults() {
    if (!confirm('Reset all settings to defaults?')) return;
    localStorage.removeItem('purl_settings');
    window.location.reload();
  }
</script>

<div class="settings-page">
  <!-- Sidebar -->
  <aside class="settings-sidebar">
    <div class="sidebar-header">
      <h2>Settings</h2>
      {#if saved}
        <span class="saved-badge">Saved</span>
      {/if}
    </div>
    <nav class="sidebar-nav">
      {#each sections as section}
        <button
          class="nav-item"
          class:active={activeSection === section.id}
          on:click={() => activeSection = section.id}
        >
          {#if section.icon === 'key'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>
            </svg>
          {:else if section.icon === 'server'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/>
            </svg>
          {:else if section.icon === 'monitor'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>
            </svg>
          {:else if section.icon === 'file-text'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><path d="M14 2v6h6M16 13H8M16 17H8M10 9H8"/>
            </svg>
          {:else if section.icon === 'bell'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M18 8A6 6 0 006 8c0 7-3 9-3 9h18s-3-2-3-9M13.73 21a2 2 0 01-3.46 0"/>
            </svg>
          {:else if section.icon === 'keyboard'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="4" width="20" height="16" rx="2"/><path d="M6 8h.01M10 8h.01M14 8h.01M18 8h.01M8 12h.01M12 12h.01M16 12h.01M7 16h10"/>
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
          <span>{section.label}</span>
        </button>
      {/each}
    </nav>
  </aside>

  <!-- Main Content -->
  <main class="settings-content">
    {#if activeSection === 'auth'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Authentication</h3>
          <p>Configure API key for accessing the Purl server</p>
        </div>

        <div class="settings-group">
          <div class="setting-item">
            <div class="setting-info">
              <label for="api-key">API Key</label>
              <span class="setting-hint">Required when authentication is enabled on the server</span>
            </div>
            <div class="api-key-input">
              <input
                id="api-key"
                type="password"
                bind:value={apiKey}
                placeholder="Enter your API key"
                on:keydown={(e) => e.key === 'Enter' && saveApiKey()}
              />
              <button class="save-btn" on:click={saveApiKey}>Save</button>
            </div>
          </div>
        </div>

        <div class="auth-info">
          <h4>How to get an API key</h4>
          <p>API keys are configured on the server via the <code>PURL_API_KEYS</code> environment variable.</p>
          <pre><code>PURL_API_KEYS=your-secret-key-here</code></pre>
          <p>Multiple keys can be set separated by commas.</p>
        </div>
      </section>
    {/if}

    {#if activeSection === 'database'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Database Configuration</h3>
          <p>ClickHouse connection and data retention settings</p>
        </div>

        <!-- ClickHouse Connection -->
        <div class="settings-group">
          <div class="group-title">ClickHouse Connection</div>

          {#if serverConfig}
            <div class="setting-item">
              <div class="setting-info">
                <span class="setting-label">Host</span>
                <span class="setting-hint">ClickHouse server address</span>
              </div>
              <code class="config-value">{serverConfig.clickhouse?.host || 'localhost'}</code>
            </div>

            <div class="setting-item">
              <div class="setting-info">
                <span class="setting-label">Port</span>
                <span class="setting-hint">HTTP interface port</span>
              </div>
              <code class="config-value">{serverConfig.clickhouse?.port || 8123}</code>
            </div>

            <div class="setting-item">
              <div class="setting-info">
                <span class="setting-label">Database</span>
                <span class="setting-hint">Database name</span>
              </div>
              <code class="config-value">{serverConfig.clickhouse?.database || 'purl'}</code>
            </div>

            <div class="setting-item">
              <div class="setting-info">
                <span class="setting-label">User</span>
                <span class="setting-hint">Database user</span>
              </div>
              <code class="config-value">{serverConfig.clickhouse?.user || 'default'}</code>
            </div>

            <div class="setting-item">
              <div class="setting-info">
                <span class="setting-label">Password</span>
                <span class="setting-hint">Database password</span>
              </div>
              <span class="config-status" class:configured={serverConfig.clickhouse?.password_set}>
                {serverConfig.clickhouse?.password_set ? 'Configured' : 'Not set'}
              </span>
            </div>

            <div class="setting-item">
              <div class="setting-info">
                <span class="setting-label">Test Connection</span>
                <span class="setting-hint">Verify ClickHouse is reachable</span>
              </div>
              <button class="test-btn" on:click={testClickHouseConnection} disabled={testingClickHouse}>
                {testingClickHouse ? 'Testing...' : 'Test'}
              </button>
            </div>

            {#if clickHouseTestResult}
              <div class="test-result-box" class:success={clickHouseTestResult.success}>
                {#if clickHouseTestResult.success}
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="20 6 9 17 4 12"/>
                  </svg>
                  {clickHouseTestResult.message}
                {:else}
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>
                  </svg>
                  {clickHouseTestResult.error}
                {/if}
              </div>
            {/if}
          {:else}
            <div class="loading-state">Loading configuration...</div>
          {/if}
        </div>

        <!-- Retention Settings -->
        <div class="settings-group" style="margin-top: 20px;">
          <div class="group-title">Data Retention</div>

          <div class="setting-item">
            <div class="setting-info">
              <label for="retention-days">Retention Period</label>
              <span class="setting-hint">How long to keep log data (TTL)</span>
            </div>
            <div class="retention-input">
              <input
                id="retention-days"
                type="number"
                min="1"
                max="365"
                bind:value={retentionDays}
              />
              <span class="retention-unit">days</span>
              <button class="save-btn" on:click={saveRetention} disabled={savingRetention}>
                {savingRetention ? 'Saving...' : 'Apply'}
              </button>
            </div>
          </div>

          {#if retentionMessage}
            <div class="retention-message" class:success={retentionMessage.success}>
              {retentionMessage.text}
            </div>
          {/if}

          {#if retentionStats}
            <div class="retention-stats">
              <div class="stat-row">
                <span>Total Logs</span>
                <span>{retentionStats.total_logs?.toLocaleString() || 0}</span>
              </div>
              <div class="stat-row">
                <span>Database Size</span>
                <span>{retentionStats.db_size_mb || 0} MB</span>
              </div>
              <div class="stat-row">
                <span>Oldest Log</span>
                <span>{retentionStats.oldest_log ? new Date(retentionStats.oldest_log).toLocaleDateString() : 'N/A'}</span>
              </div>
              <div class="stat-row">
                <span>Newest Log</span>
                <span>{retentionStats.newest_log ? new Date(retentionStats.newest_log).toLocaleDateString() : 'N/A'}</span>
              </div>
            </div>
          {/if}
        </div>

        <!-- Environment Variables Info -->
        <div class="auth-info" style="margin-top: 20px;">
          <h4>Configuration via Environment</h4>
          <p>Database settings are configured via environment variables:</p>
          <pre><code>PURL_CLICKHOUSE_HOST=your-clickhouse-host
PURL_CLICKHOUSE_PORT=8123
PURL_CLICKHOUSE_DATABASE=purl
PURL_CLICKHOUSE_USER=purl
PURL_CLICKHOUSE_PASSWORD=your-password
PURL_RETENTION_DAYS=30</code></pre>
          <p>You can connect to any ClickHouse instance - local, remote, or cloud.</p>
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
              <label for="time-range">Default Time Range</label>
              <span class="setting-hint">Initial time range when loading</span>
            </div>
            <select id="time-range" bind:value={settings.defaultTimeRange} on:change={saveSettings}>
              {#each timeRangeOptions as opt}
                <option value={opt.value}>{opt.label}</option>
              {/each}
            </select>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <label for="auto-refresh">Auto Refresh</label>
              <span class="setting-hint">Automatically refresh log data</span>
            </div>
            <select id="auto-refresh" bind:value={settings.refreshInterval} on:change={saveSettings}>
              {#each refreshOptions as opt}
                <option value={opt.value}>{opt.label}</option>
              {/each}
            </select>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <label for="max-results">Max Results</label>
              <span class="setting-hint">Maximum logs per query</span>
            </div>
            <select id="max-results" bind:value={settings.maxResults} on:change={saveSettings}>
              <option value={100}>100</option>
              <option value={250}>250</option>
              <option value={500}>500</option>
              <option value={1000}>1,000</option>
              <option value={2000}>2,000</option>
            </select>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <label for="font-size">Font Size</label>
              <span class="setting-hint">Log viewer text size</span>
            </div>
            <select id="font-size" bind:value={settings.fontSize} on:change={saveSettings}>
              {#each fontSizeOptions as opt}
                <option value={opt.value}>{opt.label}</option>
              {/each}
            </select>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Compact Mode</span>
              <span class="setting-hint">Reduce padding for more logs</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.compactMode} on:change={saveSettings}>
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
          <p>Configure how logs are displayed and formatted</p>
        </div>

        <div class="settings-group">
          <div class="setting-item">
            <div class="setting-info">
              <label for="timestamp-format">Timestamp Format</label>
              <span class="setting-hint">How to display log timestamps</span>
            </div>
            <select id="timestamp-format" bind:value={settings.timestampFormat} on:change={saveSettings}>
              {#each timestampOptions as opt}
                <option value={opt.value}>{opt.label}</option>
              {/each}
            </select>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Show Host Column</span>
              <span class="setting-hint">Display hostname in log table</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.showHost} on:change={saveSettings}>
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Show Raw Logs</span>
              <span class="setting-hint">Display raw log data column</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.showRaw} on:change={saveSettings}>
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Line Wrap</span>
              <span class="setting-hint">Wrap long log messages</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.lineWrap} on:change={saveSettings}>
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Highlight Errors</span>
              <span class="setting-hint">Highlight error/critical logs</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.highlightErrors} on:change={saveSettings}>
              <span class="toggle-slider"></span>
            </label>
          </div>

          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Auto Scroll</span>
              <span class="setting-hint">Scroll to new logs in live mode</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.autoScroll} on:change={saveSettings}>
              <span class="toggle-slider"></span>
            </label>
          </div>
        </div>
      </section>
    {/if}

    {#if activeSection === 'notifications'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Alert Notifications</h3>
          <p>Configure notification channels for alerts. Set environment variables on the server.</p>
        </div>

        <div class="notification-grid">
          <!-- Telegram -->
          <div class="notification-card" class:configured={settings.notifications.telegram.configured}>
            <div class="notification-icon telegram">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8c-.15 1.58-.8 5.42-1.13 7.19-.14.75-.42 1-.68 1.03-.58.05-1.02-.38-1.58-.75-.88-.58-1.38-.94-2.23-1.5-.99-.65-.35-1.01.22-1.59.15-.15 2.71-2.48 2.76-2.69a.2.2 0 00-.05-.18c-.06-.05-.14-.03-.21-.02-.09.02-1.49.95-4.22 2.79-.4.27-.76.41-1.08.4-.36-.01-1.04-.2-1.55-.37-.63-.2-1.12-.31-1.08-.66.02-.18.27-.36.74-.55 2.92-1.27 4.86-2.11 5.83-2.51 2.78-1.16 3.35-1.36 3.73-1.36.08 0 .27.02.39.12.1.08.13.19.14.27-.01.06.01.24 0 .38z"/>
              </svg>
            </div>
            <div class="notification-content">
              <h4>Telegram</h4>
              <p>Receive alerts via Telegram bot</p>
              <div class="env-vars">
                <code>PURL_TELEGRAM_BOT_TOKEN</code>
                <code>PURL_TELEGRAM_CHAT_ID</code>
              </div>
              {#if settings.notifications.telegram.configured}
                <div class="notification-status configured">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="20 6 9 17 4 12"/>
                  </svg>
                  Configured
                </div>
                <button class="test-btn" on:click={() => testNotification('telegram')} disabled={testingNotification === 'telegram'}>
                  {testingNotification === 'telegram' ? 'Sending...' : 'Send Test'}
                </button>
              {:else}
                <div class="notification-status">Not configured</div>
              {/if}
              {#if testResult?.type === 'telegram'}
                <div class="test-result" class:success={testResult.success}>{testResult.message}</div>
              {/if}
            </div>
          </div>

          <!-- Slack -->
          <div class="notification-card" class:configured={settings.notifications.slack.configured}>
            <div class="notification-icon slack">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
                <path d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z"/>
              </svg>
            </div>
            <div class="notification-content">
              <h4>Slack</h4>
              <p>Post alerts to Slack channel</p>
              <div class="env-vars">
                <code>PURL_SLACK_WEBHOOK_URL</code>
              </div>
              {#if settings.notifications.slack.configured}
                <div class="notification-status configured">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="20 6 9 17 4 12"/>
                  </svg>
                  Configured
                </div>
                <button class="test-btn" on:click={() => testNotification('slack')} disabled={testingNotification === 'slack'}>
                  {testingNotification === 'slack' ? 'Sending...' : 'Send Test'}
                </button>
              {:else}
                <div class="notification-status">Not configured</div>
              {/if}
              {#if testResult?.type === 'slack'}
                <div class="test-result" class:success={testResult.success}>{testResult.message}</div>
              {/if}
            </div>
          </div>

          <!-- Webhook -->
          <div class="notification-card" class:configured={settings.notifications.webhook.configured}>
            <div class="notification-icon webhook">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/>
                <path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/>
              </svg>
            </div>
            <div class="notification-content">
              <h4>Webhook</h4>
              <p>Send to custom HTTP endpoint</p>
              <div class="env-vars">
                <code>PURL_ALERT_WEBHOOK_URL</code>
              </div>
              {#if settings.notifications.webhook.configured}
                <div class="notification-status configured">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="20 6 9 17 4 12"/>
                  </svg>
                  Configured
                </div>
                <button class="test-btn" on:click={() => testNotification('webhook')} disabled={testingNotification === 'webhook'}>
                  {testingNotification === 'webhook' ? 'Sending...' : 'Send Test'}
                </button>
              {:else}
                <div class="notification-status">Not configured</div>
              {/if}
              {#if testResult?.type === 'webhook'}
                <div class="test-result" class:success={testResult.success}>{testResult.message}</div>
              {/if}
            </div>
          </div>
        </div>

        <div class="settings-group" style="margin-top: 20px;">
          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Sound Alerts</span>
              <span class="setting-hint">Play sound for new alerts</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.soundAlerts} on:change={saveSettings}>
              <span class="toggle-slider"></span>
            </label>
          </div>
        </div>
      </section>
    {/if}

    {#if activeSection === 'keyboard'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Keyboard Shortcuts</h3>
          <p>Quick access keys for common actions</p>
        </div>

        <div class="settings-group">
          <div class="setting-item">
            <div class="setting-info">
              <span class="setting-label">Enable Keyboard Shortcuts</span>
              <span class="setting-hint">Use keyboard shortcuts globally</span>
            </div>
            <label class="toggle">
              <input type="checkbox" bind:checked={settings.keyboardShortcuts} on:change={saveSettings}>
              <span class="toggle-slider"></span>
            </label>
          </div>
        </div>

        <div class="shortcuts-list">
          {#each shortcuts as shortcut}
            <div class="shortcut-item">
              <kbd class="shortcut-key">{shortcut.key}</kbd>
              <span class="shortcut-action">{shortcut.action}</span>
            </div>
          {/each}
        </div>
      </section>
    {/if}

    {#if activeSection === 'data'}
      <section class="settings-section">
        <div class="section-header">
          <h3>Data Management</h3>
          <p>Manage your application data and settings</p>
        </div>

        <div class="data-actions">
          <div class="data-card">
            <div class="data-icon">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/>
              </svg>
            </div>
            <div class="data-content">
              <h4>Export Settings</h4>
              <p>Download all settings and preferences as JSON</p>
              <button class="data-btn" on:click={exportSettings}>Export</button>
            </div>
          </div>

          <div class="data-card">
            <div class="data-icon">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M17 8l-5-5-5 5M12 3v12"/>
              </svg>
            </div>
            <div class="data-content">
              <h4>Import Settings</h4>
              <p>Restore settings from a backup file</p>
              <label class="data-btn">
                Import
                <input type="file" accept=".json" on:change={importSettings} hidden>
              </label>
            </div>
          </div>

          <div class="data-card">
            <div class="data-icon warning">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M3 6h18M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/>
              </svg>
            </div>
            <div class="data-content">
              <h4>Clear Cache</h4>
              <p>Remove temporary data and search history</p>
              <button class="data-btn warning" on:click={clearCache}>Clear Cache</button>
            </div>
          </div>

          <div class="data-card">
            <div class="data-icon danger">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>
              </svg>
            </div>
            <div class="data-content">
              <h4>Reset to Defaults</h4>
              <p>Restore all settings to factory defaults</p>
              <button class="data-btn danger" on:click={resetToDefaults}>Reset</button>
            </div>
          </div>

          <div class="data-card">
            <div class="data-icon danger">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M3 6h18M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6M10 11v6M14 11v6"/>
              </svg>
            </div>
            <div class="data-content">
              <h4>Clear All Data</h4>
              <p>Delete all local data permanently</p>
              <button class="data-btn danger" on:click={clearAllData}>Delete All</button>
            </div>
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

        <div class="about-content">
          <div class="about-logo">
            <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
              <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
              <path d="M14 2v6h6M16 13H8M16 17H8M10 9H8"/>
            </svg>
          </div>
          <h2>Purl</h2>
          <p class="about-tagline">Fast, Modern Log Aggregation</p>
          <div class="about-version">Version 1.0.0</div>

          <div class="about-tech">
            <span class="tech-badge">Perl</span>
            <span class="tech-badge">ClickHouse</span>
            <span class="tech-badge">Svelte</span>
            <span class="tech-badge">Vector</span>
          </div>

          {#if systemInfo}
            <div class="system-info">
              <div class="info-row">
                <span>Status</span>
                <span class="status-badge" class:healthy={systemInfo.status === 'ok'}>{systemInfo.status}</span>
              </div>
              <div class="info-row">
                <span>ClickHouse</span>
                <span>{systemInfo.clickhouse}</span>
              </div>
              <div class="info-row">
                <span>Uptime</span>
                <span>{Math.floor(systemInfo.uptime_secs / 60)} min</span>
              </div>
            </div>
          {/if}

          <div class="about-links">
            <a href="https://github.com" target="_blank" rel="noopener">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
              </svg>
              GitHub
            </a>
            <a href="/api/metrics" target="_blank" rel="noopener">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M3 3v18h18"/><path d="M18 9l-5-6-4 8-3-2"/>
              </svg>
              Metrics
            </a>
          </div>
        </div>
      </section>
    {/if}
  </main>
</div>

<style>
  .settings-page {
    display: flex;
    height: calc(100vh - 50px);
    overflow: hidden;
  }

  /* Sidebar */
  .settings-sidebar {
    width: 200px;
    background: #161b22;
    border-right: 1px solid #30363d;
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
  }

  .sidebar-header {
    padding: 16px;
    border-bottom: 1px solid #30363d;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .sidebar-header h2 {
    font-size: 1rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .saved-badge {
    font-size: 0.625rem;
    padding: 2px 6px;
    background: #3fb95020;
    color: #3fb950;
    border-radius: 4px;
    animation: fadeIn 0.2s;
  }

  @keyframes fadeIn {
    from { opacity: 0; }
    to { opacity: 1; }
  }

  .sidebar-nav {
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .nav-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 12px;
    background: transparent;
    border: none;
    border-radius: 6px;
    color: #8b949e;
    font-size: 0.8125rem;
    cursor: pointer;
    text-align: left;
    transition: all 0.15s;
  }

  .nav-item:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .nav-item.active {
    background: #388bfd20;
    color: #58a6ff;
  }

  /* Main Content */
  .settings-content {
    flex: 1;
    overflow-y: auto;
    padding: 24px;
  }

  .settings-section {
    max-width: 700px;
  }

  .section-header {
    margin-bottom: 24px;
  }

  .section-header h3 {
    font-size: 1.125rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0 0 4px 0;
  }

  .section-header p {
    font-size: 0.8125rem;
    color: #8b949e;
    margin: 0;
  }

  /* Settings Group */
  .settings-group {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
    overflow: hidden;
  }

  .setting-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 14px 16px;
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

  .setting-info label,
  .setting-info .setting-label {
    font-size: 0.875rem;
    color: #f0f6fc;
    font-weight: 500;
  }

  .setting-hint {
    font-size: 0.75rem;
    color: #8b949e;
  }

  /* Select */
  select {
    padding: 8px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.8125rem;
    min-width: 150px;
    cursor: pointer;
  }

  select:hover {
    border-color: #58a6ff;
  }

  /* API Key Input */
  .api-key-input {
    display: flex;
    gap: 8px;
  }

  .api-key-input input {
    padding: 8px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.8125rem;
    min-width: 250px;
    font-family: 'SF Mono', Monaco, monospace;
  }

  .api-key-input input:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .save-btn {
    padding: 8px 16px;
    background: #238636;
    border: none;
    border-radius: 6px;
    color: #fff;
    font-size: 0.8125rem;
    cursor: pointer;
    transition: background 0.2s;
  }

  .save-btn:hover {
    background: #2ea043;
  }

  .auth-info {
    margin-top: 20px;
    padding: 16px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
  }

  .auth-info h4 {
    font-size: 0.875rem;
    color: #f0f6fc;
    margin: 0 0 12px 0;
  }

  .auth-info p {
    font-size: 0.8125rem;
    color: #8b949e;
    margin: 0 0 8px 0;
  }

  .auth-info code {
    background: #21262d;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: 'SF Mono', Monaco, monospace;
    color: #58a6ff;
    font-size: 0.75rem;
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
    font-size: 0.8125rem;
  }

  /* Toggle */
  .toggle {
    position: relative;
    display: inline-block;
    width: 40px;
    height: 22px;
  }

  .toggle input {
    opacity: 0;
    width: 0;
    height: 0;
  }

  .toggle-slider {
    position: absolute;
    cursor: pointer;
    inset: 0;
    background: #21262d;
    border-radius: 22px;
    transition: 0.2s;
  }

  .toggle-slider:before {
    position: absolute;
    content: "";
    height: 16px;
    width: 16px;
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
    transform: translateX(18px);
    background: #fff;
  }

  /* Database section styles */
  .group-title {
    font-size: 0.75rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    padding: 12px 16px 8px;
    border-bottom: 1px solid #21262d;
  }

  .config-value {
    background: #21262d;
    padding: 6px 12px;
    border-radius: 6px;
    font-family: 'SF Mono', Monaco, monospace;
    font-size: 0.8125rem;
    color: #58a6ff;
  }

  .config-status {
    font-size: 0.8125rem;
    color: #8b949e;
    padding: 4px 10px;
    background: #21262d;
    border-radius: 12px;
  }

  .config-status.configured {
    color: #3fb950;
    background: #3fb95020;
  }

  .loading-state {
    padding: 20px;
    text-align: center;
    color: #8b949e;
    font-size: 0.875rem;
  }

  .test-result-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px 16px;
    margin: 0;
    background: #f8514920;
    color: #f85149;
    font-size: 0.8125rem;
    border-top: 1px solid #21262d;
  }

  .test-result-box.success {
    background: #3fb95020;
    color: #3fb950;
  }

  .retention-input {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .retention-input input {
    width: 80px;
    padding: 8px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.875rem;
    text-align: center;
  }

  .retention-input input:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .retention-unit {
    font-size: 0.8125rem;
    color: #8b949e;
  }

  .retention-message {
    padding: 10px 16px;
    font-size: 0.8125rem;
    color: #f85149;
    background: #f8514910;
    border-top: 1px solid #21262d;
  }

  .retention-message.success {
    color: #3fb950;
    background: #3fb95010;
  }

  .retention-stats {
    padding: 12px 16px;
    background: #0d1117;
    border-top: 1px solid #21262d;
  }

  .stat-row {
    display: flex;
    justify-content: space-between;
    padding: 6px 0;
    font-size: 0.8125rem;
  }

  .stat-row span:first-child {
    color: #8b949e;
  }

  .stat-row span:last-child {
    color: #f0f6fc;
    font-family: 'SF Mono', Monaco, monospace;
  }

  /* Notification Cards */
  .notification-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 16px;
  }

  .notification-card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
    padding: 16px;
    display: flex;
    gap: 14px;
  }

  .notification-card.configured {
    border-color: #3fb95040;
  }

  .notification-icon {
    width: 44px;
    height: 44px;
    border-radius: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #21262d;
    color: #8b949e;
    flex-shrink: 0;
  }

  .notification-icon.telegram { background: #0088cc20; color: #0088cc; }
  .notification-icon.slack { background: #4a154b20; color: #e01e5a; }
  .notification-icon.webhook { background: #58a6ff20; color: #58a6ff; }

  .notification-content h4 {
    font-size: 0.9375rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0 0 4px 0;
  }

  .notification-content p {
    font-size: 0.75rem;
    color: #8b949e;
    margin: 0 0 10px 0;
  }

  .env-vars {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-bottom: 10px;
  }

  .env-vars code {
    font-size: 0.625rem;
    padding: 2px 6px;
    background: #21262d;
    border-radius: 4px;
    color: #58a6ff;
    font-family: 'SF Mono', Monaco, monospace;
  }

  .notification-status {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 0.75rem;
    color: #8b949e;
    margin-bottom: 8px;
  }

  .notification-status.configured {
    color: #3fb950;
  }

  .test-btn {
    padding: 6px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.75rem;
    cursor: pointer;
    width: 100%;
  }

  .test-btn:hover:not(:disabled) {
    background: #30363d;
  }

  .test-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .test-result {
    margin-top: 8px;
    font-size: 0.75rem;
    color: #f85149;
  }

  .test-result.success {
    color: #3fb950;
  }

  /* Shortcuts */
  .shortcuts-list {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 8px;
    margin-top: 16px;
  }

  .shortcut-item {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 14px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
  }

  .shortcut-key {
    padding: 4px 8px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    font-family: 'SF Mono', Monaco, monospace;
    font-size: 0.75rem;
    color: #f0f6fc;
    min-width: 40px;
    text-align: center;
  }

  .shortcut-action {
    font-size: 0.8125rem;
    color: #8b949e;
  }

  /* Data Actions */
  .data-actions {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 12px;
  }

  .data-card {
    display: flex;
    gap: 14px;
    padding: 16px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
  }

  .data-icon {
    width: 40px;
    height: 40px;
    border-radius: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #21262d;
    color: #8b949e;
    flex-shrink: 0;
  }

  .data-icon.warning { background: #d2992220; color: #d29922; }
  .data-icon.danger { background: #f8514920; color: #f85149; }

  .data-content h4 {
    font-size: 0.875rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0 0 4px 0;
  }

  .data-content p {
    font-size: 0.75rem;
    color: #8b949e;
    margin: 0 0 10px 0;
  }

  .data-btn {
    display: inline-block;
    padding: 6px 14px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.75rem;
    cursor: pointer;
    text-align: center;
  }

  .data-btn:hover {
    background: #30363d;
  }

  .data-btn.warning {
    border-color: #d29922;
    color: #d29922;
  }

  .data-btn.warning:hover {
    background: #d2992220;
  }

  .data-btn.danger {
    border-color: #f85149;
    color: #f85149;
  }

  .data-btn.danger:hover {
    background: #f8514920;
  }

  /* About */
  .about-content {
    text-align: center;
    padding: 40px 20px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
  }

  .about-logo {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 80px;
    height: 80px;
    background: linear-gradient(135deg, #388bfd20, #a371f720);
    border-radius: 20px;
    color: #58a6ff;
    margin-bottom: 16px;
  }

  .about-content h2 {
    font-size: 1.5rem;
    font-weight: 700;
    color: #f0f6fc;
    margin: 0 0 4px 0;
  }

  .about-tagline {
    font-size: 0.875rem;
    color: #8b949e;
    margin: 0 0 8px 0;
  }

  .about-version {
    font-size: 0.75rem;
    color: #6e7681;
    font-family: 'SF Mono', Monaco, monospace;
    margin-bottom: 20px;
  }

  .about-tech {
    display: flex;
    justify-content: center;
    gap: 8px;
    margin-bottom: 24px;
    flex-wrap: wrap;
  }

  .tech-badge {
    padding: 4px 10px;
    background: #21262d;
    border-radius: 12px;
    font-size: 0.75rem;
    color: #c9d1d9;
  }

  .system-info {
    display: inline-flex;
    flex-direction: column;
    gap: 8px;
    padding: 16px 24px;
    background: #0d1117;
    border-radius: 8px;
    margin-bottom: 24px;
    text-align: left;
  }

  .info-row {
    display: flex;
    justify-content: space-between;
    gap: 32px;
    font-size: 0.8125rem;
    color: #8b949e;
  }

  .info-row span:last-child {
    color: #f0f6fc;
    font-family: 'SF Mono', Monaco, monospace;
  }

  .status-badge {
    padding: 2px 8px;
    border-radius: 10px;
    font-size: 0.6875rem;
    text-transform: uppercase;
    background: #8b949e20;
  }

  .status-badge.healthy {
    background: #3fb95020;
    color: #3fb950;
  }

  .about-links {
    display: flex;
    justify-content: center;
    gap: 16px;
  }

  .about-links a {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 14px;
    background: #21262d;
    border-radius: 6px;
    color: #c9d1d9;
    text-decoration: none;
    font-size: 0.8125rem;
  }

  .about-links a:hover {
    background: #30363d;
  }

  /* Responsive */
  @media (max-width: 768px) {
    .settings-page {
      flex-direction: column;
      height: auto;
    }

    .settings-sidebar {
      width: 100%;
      border-right: none;
      border-bottom: 1px solid #30363d;
    }

    .sidebar-nav {
      flex-direction: row;
      overflow-x: auto;
      padding: 8px 12px;
    }

    .nav-item {
      flex-shrink: 0;
    }

    .settings-content {
      min-height: calc(100vh - 150px);
    }
  }
</style>
