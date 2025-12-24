<!--
  ShortcutsSettings Component
  Keyboard shortcuts configuration and reference

  Usage:
  <ShortcutsSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Toggle from '../ui/Toggle.svelte';
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';

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

  <Card padding="none">
    <div class="setting-item">
      <Toggle
        bind:checked={settings.keyboardShortcuts}
        label="Enable Keyboard Shortcuts"
        description="Turn keyboard shortcuts on/off"
        labelPosition="left"
        on:change={saveSettings}
      />
    </div>
  </Card>

  <Card padding="none" title="Available Shortcuts" class="shortcuts-card">
    <div class="shortcuts-list">
      {#each shortcuts as shortcut}
        <div class="shortcut-item">
          <Badge variant="default">{shortcut.key}</Badge>
          <span class="shortcut-action">{shortcut.action}</span>
        </div>
      {/each}
    </div>
  </Card>
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
  }

  :global(.shortcuts-card) {
    margin-top: 16px;
  }

  .shortcuts-list {
    display: flex;
    flex-direction: column;
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

  .shortcut-action {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
  }
</style>
