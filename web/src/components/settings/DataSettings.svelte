<!--
  DataSettings Component
  Cache and local storage management

  Usage:
  <DataSettings />
-->
<script>
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
      <button class="danger-btn" on:click={clearLocalStorage}>Reset</button>
    </div>
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

  .danger-btn {
    padding: 8px 16px;
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--color-error, #f85149);
    border-radius: 6px;
    color: var(--color-error, #f85149);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .danger-btn:hover {
    background: rgba(248, 81, 73, 0.15);
  }
</style>
