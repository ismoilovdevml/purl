<!--
  SettingsPage Component
  Main settings page with navigation sidebar

  Usage:
  <SettingsPage />
-->
<script>
  import DatabaseSettings from './DatabaseSettings.svelte';
  import NotificationSettings from './NotificationSettings.svelte';
  import DisplaySettings from './DisplaySettings.svelte';
  import ShortcutsSettings from './ShortcutsSettings.svelte';
  import DataSettings from './DataSettings.svelte';
  import AboutSettings from './AboutSettings.svelte';

  let activeSection = 'database';

  const sections = [
    { id: 'database', label: 'Database', icon: 'server' },
    { id: 'notifications', label: 'Notifications', icon: 'bell' },
    { id: 'display', label: 'Display', icon: 'monitor' },
    { id: 'shortcuts', label: 'Shortcuts', icon: 'keyboard' },
    { id: 'data', label: 'Data', icon: 'database' },
    { id: 'about', label: 'About', icon: 'info' },
  ];
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
          {:else if section.icon === 'bell'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>
            </svg>
          {:else if section.icon === 'monitor'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>
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
      <DatabaseSettings />
    {:else if activeSection === 'notifications'}
      <NotificationSettings />
    {:else if activeSection === 'display'}
      <DisplaySettings />
    {:else if activeSection === 'shortcuts'}
      <ShortcutsSettings />
    {:else if activeSection === 'data'}
      <DataSettings />
    {:else if activeSection === 'about'}
      <AboutSettings />
    {/if}
  </main>
</div>

<style>
  .settings-page {
    display: flex;
    height: calc(100vh - 60px);
    background: var(--bg-primary, #0d1117);
    color: var(--text-primary, #c9d1d9);
    overflow: hidden;
  }

  .settings-nav {
    width: 220px;
    background: var(--bg-secondary, #161b22);
    border-right: 1px solid var(--border-color, #21262d);
    padding: 20px 0;
    flex-shrink: 0;
    overflow-y: auto;
  }

  .settings-nav h2 {
    font-size: 1rem;
    font-weight: 600;
    padding: 0 16px 16px;
    margin: 0;
    border-bottom: 1px solid var(--border-color, #21262d);
    color: var(--text-primary, #f0f6fc);
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
    color: var(--text-secondary, #8b949e);
    font-size: 0.875rem;
    cursor: pointer;
    transition: all 0.15s;
    text-align: left;
  }

  .nav-item:hover {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .nav-item.active {
    background: rgba(31, 111, 235, 0.15);
    color: var(--color-primary, #58a6ff);
    border-left: 2px solid var(--color-primary, #58a6ff);
  }

  .settings-content {
    flex: 1;
    padding: 24px 32px;
    overflow-y: auto;
    height: 100%;
  }
</style>
