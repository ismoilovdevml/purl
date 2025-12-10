<script>
  import { onMount } from 'svelte';

  let settings = {
    theme: 'dark',
    refreshInterval: 30,
    defaultTimeRange: '15m',
    maxResults: 500,
    showHost: false,
    compactMode: false,
    notifications: {
      telegram: { enabled: false, configured: false },
      slack: { enabled: false, configured: false },
      webhook: { enabled: false, configured: false }
    }
  };

  let testingNotification = null;
  let testResult = null;
  let saved = false;

  const API_BASE = '/api';

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
    { value: 10, label: '10 seconds' },
    { value: 30, label: '30 seconds' },
    { value: 60, label: '1 minute' },
    { value: 300, label: '5 minutes' },
  ];

  onMount(() => {
    loadSettings();
    checkNotificationStatus();
  });

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

    // Dispatch event for other components
    window.dispatchEvent(new CustomEvent('settings-changed', { detail: settings }));
  }

  async function checkNotificationStatus() {
    try {
      const res = await fetch(`${API_BASE}/metrics/json`);
      if (res.ok) {
        const data = await res.json();
        // Check if notifiers are configured based on server response
        settings.notifications.telegram.configured = !!data.notifiers?.telegram;
        settings.notifications.slack.configured = !!data.notifiers?.slack;
        settings.notifications.webhook.configured = !!data.notifiers?.webhook;
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

      if (data.success) {
        testResult = { type, success: true, message: 'Test message sent!' };
      } else {
        testResult = { type, success: false, message: data.error || 'Failed to send' };
      }
    } catch (err) {
      testResult = { type, success: false, message: err.message };
    } finally {
      testingNotification = null;
    }
  }

  async function clearAllData() {
    if (!confirm('Are you sure you want to clear all local data? This includes saved searches, column settings, and preferences.')) {
      return;
    }

    localStorage.removeItem('purl_settings');
    localStorage.removeItem('purl_column_config');
    localStorage.removeItem('purl_search_history');
    localStorage.removeItem('purl_saved_searches');

    window.location.reload();
  }

  function exportSettings() {
    const data = {
      settings,
      columnConfig: localStorage.getItem('purl_column_config'),
      savedSearches: localStorage.getItem('purl_saved_searches'),
      exportDate: new Date().toISOString()
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
        if (data.columnConfig) {
          localStorage.setItem('purl_column_config', data.columnConfig);
        }
        if (data.savedSearches) {
          localStorage.setItem('purl_saved_searches', data.savedSearches);
        }
        alert('Settings imported successfully!');
      } catch {
        alert('Failed to import settings: Invalid file format');
      }
    };
    reader.readAsText(file);
  }
</script>

<div class="settings-page">
  <header class="page-header">
    <h1>
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="12" cy="12" r="3"/>
        <path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-2 2 2 2 0 01-2-2v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83 0 2 2 0 010-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 01-2-2 2 2 0 012-2h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 010-2.83 2 2 0 012.83 0l.06.06a1.65 1.65 0 001.82.33H9a1.65 1.65 0 001-1.51V3a2 2 0 012-2 2 2 0 012 2v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 0 2 2 0 010 2.83l-.06.06a1.65 1.65 0 00-.33 1.82V9a1.65 1.65 0 001.51 1H21a2 2 0 012 2 2 2 0 01-2 2h-.09a1.65 1.65 0 00-1.51 1z"/>
      </svg>
      Settings
    </h1>
    {#if saved}
      <span class="saved-indicator">Saved!</span>
    {/if}
  </header>

  <!-- Display Settings -->
  <section class="settings-section">
    <h2>Display</h2>

    <div class="setting-row">
      <div class="setting-info">
        <label for="time-range">Default Time Range</label>
        <span class="setting-desc">Initial time range when loading the dashboard</span>
      </div>
      <select id="time-range" bind:value={settings.defaultTimeRange} on:change={saveSettings}>
        {#each timeRangeOptions as opt}
          <option value={opt.value}>{opt.label}</option>
        {/each}
      </select>
    </div>

    <div class="setting-row">
      <div class="setting-info">
        <label for="auto-refresh">Auto Refresh</label>
        <span class="setting-desc">Automatically refresh log data</span>
      </div>
      <select id="auto-refresh" bind:value={settings.refreshInterval} on:change={saveSettings}>
        {#each refreshOptions as opt}
          <option value={opt.value}>{opt.label}</option>
        {/each}
      </select>
    </div>

    <div class="setting-row">
      <div class="setting-info">
        <label for="max-results">Max Results</label>
        <span class="setting-desc">Maximum logs to fetch per query</span>
      </div>
      <select id="max-results" bind:value={settings.maxResults} on:change={saveSettings}>
        <option value={100}>100</option>
        <option value={250}>250</option>
        <option value={500}>500</option>
        <option value={1000}>1000</option>
      </select>
    </div>

    <div class="setting-row">
      <div class="setting-info">
        <span class="setting-label">Show Host Column</span>
        <span class="setting-desc">Display host column in log table by default</span>
      </div>
      <label class="toggle">
        <input type="checkbox" bind:checked={settings.showHost} on:change={saveSettings}>
        <span class="toggle-slider"></span>
      </label>
    </div>

    <div class="setting-row">
      <div class="setting-info">
        <span class="setting-label">Compact Mode</span>
        <span class="setting-desc">Reduce padding for more logs on screen</span>
      </div>
      <label class="toggle">
        <input type="checkbox" bind:checked={settings.compactMode} on:change={saveSettings}>
        <span class="toggle-slider"></span>
      </label>
    </div>
  </section>

  <!-- Notifications -->
  <section class="settings-section">
    <h2>Alert Notifications</h2>
    <p class="section-desc">Configure notification channels for alerts. Set environment variables on the server to enable.</p>

    <div class="notification-cards">
      <div class="notification-card">
        <div class="notification-header">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
            <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8c-.15 1.58-.8 5.42-1.13 7.19-.14.75-.42 1-.68 1.03-.58.05-1.02-.38-1.58-.75-.88-.58-1.38-.94-2.23-1.5-.99-.65-.35-1.01.22-1.59.15-.15 2.71-2.48 2.76-2.69a.2.2 0 00-.05-.18c-.06-.05-.14-.03-.21-.02-.09.02-1.49.95-4.22 2.79-.4.27-.76.41-1.08.4-.36-.01-1.04-.2-1.55-.37-.63-.2-1.12-.31-1.08-.66.02-.18.27-.36.74-.55 2.92-1.27 4.86-2.11 5.83-2.51 2.78-1.16 3.35-1.36 3.73-1.36.08 0 .27.02.39.12.1.08.13.19.14.27-.01.06.01.24 0 .38z"/>
          </svg>
          <span>Telegram</span>
          {#if settings.notifications.telegram.configured}
            <span class="badge configured">Configured</span>
          {:else}
            <span class="badge">Not configured</span>
          {/if}
        </div>
        <p class="notification-desc">Receive alerts via Telegram bot</p>
        <div class="notification-env">
          <code>PURL_TELEGRAM_BOT_TOKEN</code>
          <code>PURL_TELEGRAM_CHAT_ID</code>
        </div>
        {#if settings.notifications.telegram.configured}
          <button
            class="test-btn"
            on:click={() => testNotification('telegram')}
            disabled={testingNotification === 'telegram'}
          >
            {testingNotification === 'telegram' ? 'Sending...' : 'Send Test'}
          </button>
        {/if}
        {#if testResult?.type === 'telegram'}
          <span class="test-result" class:success={testResult.success}>{testResult.message}</span>
        {/if}
      </div>

      <div class="notification-card">
        <div class="notification-header">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
            <path d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z"/>
          </svg>
          <span>Slack</span>
          {#if settings.notifications.slack.configured}
            <span class="badge configured">Configured</span>
          {:else}
            <span class="badge">Not configured</span>
          {/if}
        </div>
        <p class="notification-desc">Post alerts to Slack channel</p>
        <div class="notification-env">
          <code>PURL_SLACK_WEBHOOK_URL</code>
        </div>
        {#if settings.notifications.slack.configured}
          <button
            class="test-btn"
            on:click={() => testNotification('slack')}
            disabled={testingNotification === 'slack'}
          >
            {testingNotification === 'slack' ? 'Sending...' : 'Send Test'}
          </button>
        {/if}
        {#if testResult?.type === 'slack'}
          <span class="test-result" class:success={testResult.success}>{testResult.message}</span>
        {/if}
      </div>

      <div class="notification-card">
        <div class="notification-header">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/>
            <path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/>
          </svg>
          <span>Webhook</span>
          {#if settings.notifications.webhook.configured}
            <span class="badge configured">Configured</span>
          {:else}
            <span class="badge">Not configured</span>
          {/if}
        </div>
        <p class="notification-desc">Send alerts to custom HTTP endpoint</p>
        <div class="notification-env">
          <code>PURL_ALERT_WEBHOOK_URL</code>
        </div>
        {#if settings.notifications.webhook.configured}
          <button
            class="test-btn"
            on:click={() => testNotification('webhook')}
            disabled={testingNotification === 'webhook'}
          >
            {testingNotification === 'webhook' ? 'Sending...' : 'Send Test'}
          </button>
        {/if}
        {#if testResult?.type === 'webhook'}
          <span class="test-result" class:success={testResult.success}>{testResult.message}</span>
        {/if}
      </div>
    </div>
  </section>

  <!-- Data Management -->
  <section class="settings-section">
    <h2>Data Management</h2>

    <div class="action-buttons">
      <button class="action-btn" on:click={exportSettings}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/>
        </svg>
        Export Settings
      </button>

      <label class="action-btn">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M17 8l-5-5-5 5M12 3v12"/>
        </svg>
        Import Settings
        <input type="file" accept=".json" on:change={importSettings} hidden>
      </label>

      <button class="action-btn danger" on:click={clearAllData}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M3 6h18M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/>
        </svg>
        Clear All Data
      </button>
    </div>
  </section>

  <!-- About -->
  <section class="settings-section about">
    <h2>About</h2>
    <div class="about-info">
      <p><strong>Purl</strong> - Log Aggregation Dashboard</p>
      <p>Built with Perl + ClickHouse + Svelte</p>
      <p class="version">Version 1.0.0</p>
    </div>
  </section>
</div>

<style>
  .settings-page {
    padding: 20px;
    max-width: 800px;
    margin: 0 auto;
  }

  .page-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 24px;
  }

  .page-header h1 {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 1.5rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .saved-indicator {
    color: #3fb950;
    font-size: 0.875rem;
    animation: fadeIn 0.3s ease;
  }

  @keyframes fadeIn {
    from { opacity: 0; }
    to { opacity: 1; }
  }

  .settings-section {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 20px;
    margin-bottom: 20px;
  }

  .settings-section h2 {
    font-size: 1rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0 0 16px 0;
  }

  .section-desc {
    color: #8b949e;
    font-size: 0.875rem;
    margin: -8px 0 16px 0;
  }

  .setting-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 0;
    border-bottom: 1px solid #21262d;
  }

  .setting-row:last-child {
    border-bottom: none;
  }

  .setting-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .setting-info label,
  .setting-info .setting-label {
    color: #f0f6fc;
    font-weight: 500;
  }

  .setting-desc {
    color: #8b949e;
    font-size: 0.75rem;
  }

  select {
    padding: 8px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.875rem;
    cursor: pointer;
  }

  select:hover {
    border-color: #58a6ff;
  }

  /* Toggle Switch */
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
    border-radius: 24px;
    transition: 0.3s;
  }

  .toggle-slider:before {
    position: absolute;
    content: "";
    height: 18px;
    width: 18px;
    left: 3px;
    bottom: 3px;
    background: #c9d1d9;
    border-radius: 50%;
    transition: 0.3s;
  }

  .toggle input:checked + .toggle-slider {
    background: #238636;
  }

  .toggle input:checked + .toggle-slider:before {
    transform: translateX(20px);
  }

  /* Notification Cards */
  .notification-cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 16px;
  }

  .notification-card {
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 16px;
  }

  .notification-header {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
    color: #f0f6fc;
    font-weight: 500;
  }

  .notification-header svg {
    color: #8b949e;
  }

  .badge {
    font-size: 0.625rem;
    padding: 2px 6px;
    border-radius: 10px;
    background: #21262d;
    color: #8b949e;
    text-transform: uppercase;
  }

  .badge.configured {
    background: #238636;
    color: #fff;
  }

  .notification-desc {
    font-size: 0.75rem;
    color: #8b949e;
    margin: 0 0 12px 0;
  }

  .notification-env {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-bottom: 12px;
  }

  .notification-env code {
    font-size: 0.625rem;
    padding: 2px 6px;
    background: #21262d;
    border-radius: 4px;
    color: #58a6ff;
    font-family: 'SF Mono', Monaco, monospace;
  }

  .test-btn {
    width: 100%;
    padding: 8px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.75rem;
    cursor: pointer;
  }

  .test-btn:hover:not(:disabled) {
    background: #30363d;
  }

  .test-btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .test-result {
    display: block;
    margin-top: 8px;
    font-size: 0.75rem;
    color: #f85149;
  }

  .test-result.success {
    color: #3fb950;
  }

  /* Action Buttons */
  .action-buttons {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  .action-btn {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.875rem;
    cursor: pointer;
  }

  .action-btn:hover {
    background: #30363d;
  }

  .action-btn.danger {
    border-color: #f85149;
    color: #f85149;
  }

  .action-btn.danger:hover {
    background: #f8514926;
  }

  /* About */
  .about-info {
    color: #8b949e;
    font-size: 0.875rem;
  }

  .about-info p {
    margin: 4px 0;
  }

  .about-info .version {
    margin-top: 12px;
    font-family: 'SF Mono', Monaco, monospace;
    color: #6e7681;
  }
</style>
