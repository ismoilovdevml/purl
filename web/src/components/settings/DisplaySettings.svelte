<!--
  DisplaySettings Component
  Display preferences and log viewer settings

  Usage:
  <DisplaySettings />
-->
<script>
  import { onMount } from 'svelte';
  import Select from '../ui/Select.svelte';
  import Input from '../ui/Input.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import Card from '../ui/Card.svelte';

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

  const timestampOptions = [
    { value: 'relative', label: 'Relative (5 min ago)' },
    { value: 'absolute', label: 'Absolute (12:34:56)' },
    { value: 'iso', label: 'ISO 8601' },
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

  function handleChange() {
    saveSettings();
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Display Settings</h3>
    <p>Customize the appearance of your dashboard</p>
  </div>

  <Card padding="none">
    <div class="setting-item">
      <div class="setting-info">
        <span class="setting-label">Default Time Range</span>
        <span class="setting-hint">Initial time range when opening logs</span>
      </div>
      <Select
        bind:value={settings.defaultTimeRange}
        options={timeRangeOptions}
        on:change={handleChange}
      />
    </div>

    <div class="setting-item">
      <div class="setting-info">
        <span class="setting-label">Refresh Interval</span>
        <span class="setting-hint">Auto-refresh interval in seconds (0 = disabled)</span>
      </div>
      <Input
        type="number"
        min={0}
        max={300}
        bind:value={settings.refreshInterval}
        on:change={handleChange}
      />
    </div>

    <div class="setting-item">
      <div class="setting-info">
        <span class="setting-label">Max Results</span>
        <span class="setting-hint">Maximum number of logs to display</span>
      </div>
      <Input
        type="number"
        min={50}
        max={5000}
        bind:value={settings.maxResults}
        on:change={handleChange}
      />
    </div>

    <div class="setting-item">
      <Toggle
        bind:checked={settings.compactMode}
        label="Compact Mode"
        description="Reduce spacing in log list"
        labelPosition="left"
        on:change={handleChange}
      />
    </div>

    <div class="setting-item">
      <Toggle
        bind:checked={settings.lineWrap}
        label="Line Wrap"
        description="Wrap long log messages"
        labelPosition="left"
        on:change={handleChange}
      />
    </div>
  </Card>

  <div class="section-header" style="margin-top: 32px;">
    <h3>Log Viewer Settings</h3>
    <p>Configure log display preferences</p>
  </div>

  <Card padding="none">
    <div class="setting-item">
      <Toggle
        bind:checked={settings.showHost}
        label="Show Host Column"
        description="Display host information in log list"
        labelPosition="left"
        on:change={handleChange}
      />
    </div>

    <div class="setting-item">
      <Toggle
        bind:checked={settings.showRaw}
        label="Show Raw Messages"
        description="Display raw log data by default"
        labelPosition="left"
        on:change={handleChange}
      />
    </div>

    <div class="setting-item">
      <Toggle
        bind:checked={settings.highlightErrors}
        label="Highlight Errors"
        description="Highlight ERROR and FATAL logs"
        labelPosition="left"
        on:change={handleChange}
      />
    </div>

    <div class="setting-item">
      <Toggle
        bind:checked={settings.autoScroll}
        label="Auto Scroll"
        description="Auto-scroll to new logs in live mode"
        labelPosition="left"
        on:change={handleChange}
      />
    </div>

    <div class="setting-item">
      <div class="setting-info">
        <span class="setting-label">Timestamp Format</span>
        <span class="setting-hint">How to display timestamps</span>
      </div>
      <Select
        bind:value={settings.timestampFormat}
        options={timestampOptions}
        on:change={handleChange}
      />
    </div>
  </Card>

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
