<!--
  DisplaySettings Component
  Display preferences and log viewer settings

  Usage:
  <DisplaySettings />
-->
<script>
  import Select from '../ui/Select.svelte';
  import Input from '../ui/Input.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import Card from '../ui/Card.svelte';
  import { settings } from '../../stores/settings.js';

  let saved = false;
  let localSettings;

  // Subscribe to store
  $: localSettings = $settings;

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

  function updateSetting(key, value) {
    settings.setSetting(key, value);
    showSaved();
  }

  function showSaved() {
    saved = true;
    setTimeout(() => saved = false, 2000);
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
        value={localSettings.defaultTimeRange}
        options={timeRangeOptions}
        on:change={(e) => updateSetting('defaultTimeRange', e.detail || e.target.value)}
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
        value={localSettings.refreshInterval}
        on:change={(e) => updateSetting('refreshInterval', parseInt(e.target.value) || 0)}
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
        value={localSettings.maxResults}
        on:change={(e) => updateSetting('maxResults', parseInt(e.target.value) || 500)}
      />
    </div>

    <div class="setting-item">
      <Toggle
        checked={localSettings.compactMode}
        label="Compact Mode"
        description="Reduce spacing in log list"
        labelPosition="left"
        on:change={() => updateSetting('compactMode', !localSettings.compactMode)}
      />
    </div>

    <div class="setting-item">
      <Toggle
        checked={localSettings.lineWrap}
        label="Line Wrap"
        description="Wrap long log messages"
        labelPosition="left"
        on:change={() => updateSetting('lineWrap', !localSettings.lineWrap)}
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
        checked={localSettings.showHost}
        label="Show Host Column"
        description="Display host information in log list"
        labelPosition="left"
        on:change={() => updateSetting('showHost', !localSettings.showHost)}
      />
    </div>

    <div class="setting-item">
      <Toggle
        checked={localSettings.showRaw}
        label="Show Raw Messages"
        description="Display raw log data by default"
        labelPosition="left"
        on:change={() => updateSetting('showRaw', !localSettings.showRaw)}
      />
    </div>

    <div class="setting-item">
      <Toggle
        checked={localSettings.highlightErrors}
        label="Highlight Errors"
        description="Highlight ERROR and FATAL logs"
        labelPosition="left"
        on:change={() => updateSetting('highlightErrors', !localSettings.highlightErrors)}
      />
    </div>

    <div class="setting-item">
      <Toggle
        checked={localSettings.autoScroll}
        label="Auto Scroll"
        description="Auto-scroll to new logs in live mode"
        labelPosition="left"
        on:change={() => updateSetting('autoScroll', !localSettings.autoScroll)}
      />
    </div>

    <div class="setting-item">
      <div class="setting-info">
        <span class="setting-label">Timestamp Format</span>
        <span class="setting-hint">How to display timestamps</span>
      </div>
      <Select
        value={localSettings.timestampFormat}
        options={timestampOptions}
        on:change={(e) => updateSetting('timestampFormat', e.detail || e.target.value)}
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
