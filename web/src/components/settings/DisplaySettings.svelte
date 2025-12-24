<!--
  DisplaySettings Component
  Display preferences and log viewer settings

  Usage:
  <DisplaySettings />
-->
<script>
  import { onMount } from 'svelte';

  let settings = {
    defaultTimeRange: '15m',
    refreshInterval: 30,
    maxResults: 500,
    compactMode: false,
    lineWrap: true,
    showHost: true,
    showRaw: false,
    highlightErrors: true,
    autoScroll: true,
    timestampFormat: 'relative',
  };

  let saved = false;

  const timeRangeOptions = [
    { value: '5m', label: '5 minutes' },
    { value: '15m', label: '15 minutes' },
    { value: '1h', label: '1 hour' },
    { value: '24h', label: '24 hours' },
    { value: '7d', label: '7 days' },
  ];

  onMount(() => {
    loadSettings();
  });

  function loadSettings() {
    const savedData = localStorage.getItem('purl_settings');
    if (savedData) {
      settings = { ...settings, ...JSON.parse(savedData) };
    }
  }

  function saveSettings() {
    localStorage.setItem('purl_settings', JSON.stringify(settings));
    saved = true;
    setTimeout(() => saved = false, 2000);
  }
</script>

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

  <div class="section-header" style="margin-top: 32px;">
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

  {#if saved}
    <div class="save-toast">Settings saved!</div>
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

  .setting-label {
    font-size: 0.875rem;
    color: var(--text-primary, #c9d1d9);
  }

  .setting-hint {
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
  }

  select {
    padding: 8px 12px;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-primary, #c9d1d9);
    font-size: 0.875rem;
  }

  input[type="number"] {
    width: 80px;
    padding: 8px 12px;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-primary, #c9d1d9);
    text-align: center;
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
    background: var(--bg-tertiary, #21262d);
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
    background: var(--text-secondary, #8b949e);
    border-radius: 50%;
    transition: 0.2s;
  }

  .toggle input:checked + .toggle-slider {
    background: var(--color-success, #238636);
  }

  .toggle input:checked + .toggle-slider:before {
    transform: translateX(20px);
    background: #fff;
  }

  .save-toast {
    position: fixed;
    bottom: 24px;
    right: 24px;
    padding: 12px 20px;
    background: var(--color-success, #238636);
    border-radius: 6px;
    color: #fff;
    font-size: 0.875rem;
    animation: slideIn 0.2s ease;
    z-index: 1000;
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
