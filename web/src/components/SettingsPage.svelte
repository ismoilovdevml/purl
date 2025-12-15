<script>
  import { onMount } from 'svelte';
  import { fetchSettings, fetchHealth, clearCache as apiClearCache } from '../lib/api.js';

  // Import sub-components
  import DatabaseSettings from './settings/DatabaseSettings.svelte';
  import NotificationSettings from './settings/NotificationSettings.svelte';
  import AboutSection from './settings/AboutSection.svelte';

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
  let serverSettings = null;
  let loadingSettings = true;

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
    loadServerSettings();
  });

  async function loadServerSettings() {
    loadingSettings = true;
    try {
      serverSettings = await fetchSettings();
    } catch {
      // Ignore
    } finally {
      loadingSettings = false;
    }
  }

  function loadSettings() {
    const savedSettings = localStorage.getItem('purl_settings');
    if (savedSettings) {
      settings = { ...settings, ...JSON.parse(savedSettings) };
    }
  }

  function saveSettings() {
    localStorage.setItem('purl_settings', JSON.stringify(settings));
    saved = true;
    setTimeout(() => saved = false, 2000);
  }

  async function fetchSystemInfo() {
    try {
      systemInfo = await fetchHealth();
    } catch {
      // Ignore
    }
  }

  async function clearCache() {
    try {
      await apiClearCache();
      alert('Cache cleared successfully');
    } catch {
      alert('Failed to clear cache');
    }
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
      <DatabaseSettings {serverSettings} {loadingSettings} on:reload={loadServerSettings} />
    {/if}

    {#if activeSection === 'notifications'}
      <NotificationSettings {serverSettings} />
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
      <AboutSection {systemInfo} />
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

  .settings-nav nav { padding: 8px 0; }

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

  .nav-item:hover { background: #21262d; color: #c9d1d9; }
  .nav-item.active { background: #1f6feb20; color: #58a6ff; border-left: 2px solid #58a6ff; }

  .settings-content {
    flex: 1;
    padding: 24px 32px;
    overflow-y: auto;
  }

  .settings-section { max-width: 800px; }
  .section-header { margin-bottom: 24px; }
  .section-header h3 { font-size: 1.25rem; font-weight: 600; color: #f0f6fc; margin: 0 0 4px; }
  .section-header p { font-size: 0.875rem; color: #8b949e; margin: 0; }

  .settings-group {
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 8px;
    overflow: hidden;
  }

  .setting-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid #21262d;
  }

  .setting-item:last-child { border-bottom: none; }
  .setting-info { display: flex; flex-direction: column; gap: 2px; }
  .setting-label { font-size: 0.875rem; color: #c9d1d9; }
  .setting-hint { font-size: 0.75rem; color: #8b949e; }

  .toggle {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
  }

  .toggle input { opacity: 0; width: 0; height: 0; }

  .toggle-slider {
    position: absolute;
    cursor: pointer;
    top: 0; left: 0; right: 0; bottom: 0;
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

  .toggle input:checked + .toggle-slider { background: #238636; }
  .toggle input:checked + .toggle-slider:before { transform: translateX(20px); background: #fff; }

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

  .shortcut-item:last-child { border-bottom: none; }

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

  .shortcut-item span { font-size: 0.875rem; color: #8b949e; }

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

  .danger-btn:hover { background: #f8514920; }

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
    from { transform: translateY(20px); opacity: 0; }
    to { transform: translateY(0); opacity: 1; }
  }
</style>
