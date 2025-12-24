<!--
  DataSettings Component
  Cache and local storage management

  Usage:
  <DataSettings />
-->
<script>
  import Button from '../ui/Button.svelte';
  import Card from '../ui/Card.svelte';

  const API_BASE = '/api';

  function getHeaders() {
    return { 'Content-Type': 'application/json' };
  }

  async function clearCache() {
    try {
      await fetch(`${API_BASE}/cache`, { method: 'DELETE', headers: getHeaders() });
      alert('Cache cleared successfully');
    } catch {
      alert('Failed to clear cache');
    }
  }

  function clearLocalStorage() {
    localStorage.clear();
    location.reload();
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Data Management</h3>
    <p>Manage cache and stored data</p>
  </div>

  <Card padding="none">
    <div class="setting-item">
      <div class="setting-info">
        <span class="setting-label">Clear Query Cache</span>
        <span class="setting-hint">Clear server-side query cache</span>
      </div>
      <Button variant="danger" on:click={clearCache}>Clear Cache</Button>
    </div>

    <div class="setting-item">
      <div class="setting-info">
        <span class="setting-label">Clear Local Storage</span>
        <span class="setting-hint">Reset all client-side settings</span>
      </div>
      <Button variant="danger" on:click={clearLocalStorage}>Reset</Button>
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
</style>
