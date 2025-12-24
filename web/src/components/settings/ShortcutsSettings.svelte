<!--
  ShortcutsSettings Component
  Keyboard shortcuts configuration and reference

  Usage:
  <ShortcutsSettings />
-->
<script>
  import { onMount } from 'svelte';

  let settings = {
    keyboardShortcuts: true,
  };

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
  });

  function loadSettings() {
    const savedData = localStorage.getItem('purl_settings');
    if (savedData) {
      const parsed = JSON.parse(savedData);
      settings.keyboardShortcuts = parsed.keyboardShortcuts ?? true;
    }
  }

  function saveSettings() {
    const savedData = localStorage.getItem('purl_settings');
    const existing = savedData ? JSON.parse(savedData) : {};
    localStorage.setItem('purl_settings', JSON.stringify({
      ...existing,
      keyboardShortcuts: settings.keyboardShortcuts
    }));
  }
</script>

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

  .shortcuts-list {
    margin-top: 16px;
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #21262d);
    border-radius: 8px;
    overflow: hidden;
  }

  .shortcut-item {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 10px 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .shortcut-item:last-child {
    border-bottom: none;
  }

  .shortcut-item kbd {
    min-width: 50px;
    padding: 4px 8px;
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 4px;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
    color: var(--text-primary, #f0f6fc);
    text-align: center;
  }

  .shortcut-item span {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
  }
</style>
