<script>
  import { onMount, onDestroy } from 'svelte';

  let alerts = [];
  let showModal = false;
  let editingAlert = null;

  let form = {
    name: '',
    query: '',
    threshold: 10,
    window_minutes: 5,
    notify_type: 'webhook',
    notify_target: ''
  };

  const API_BASE = '/api';
  let checkInterval;

  onMount(() => {
    loadAlerts();
    checkInterval = setInterval(checkAlerts, 60000);
  });

  onDestroy(() => {
    if (checkInterval) clearInterval(checkInterval);
  });

  async function loadAlerts() {
    try {
      const res = await fetch(`${API_BASE}/alerts`);
      const data = await res.json();
      alerts = data.alerts || [];
    } catch (err) {
      console.error('Failed to load alerts:', err);
    }
  }

  async function checkAlerts() {
    try {
      const res = await fetch(`${API_BASE}/alerts/check`, { method: 'POST' });
      const data = await res.json();
      if (data.triggered && data.triggered.length > 0) {
        for (const alert of data.triggered) {
          showNotification(alert);
        }
        await loadAlerts();
      }
    } catch (err) {
      console.error('Alert check failed:', err);
    }
  }

  function showNotification(alert) {
    if ('Notification' in window && Notification.permission === 'granted') {
      new Notification(`Alert: ${alert.name}`, {
        body: `${alert.count} logs matched "${alert.query}"`,
        icon: '/favicon.ico'
      });
    }
  }

  function openModal(alert = null) {
    if (alert) {
      editingAlert = alert;
      form = {
        name: alert.name,
        query: alert.query,
        threshold: alert.threshold,
        window_minutes: alert.window_minutes,
        notify_type: alert.notify_type,
        notify_target: alert.notify_target
      };
    } else {
      editingAlert = null;
      form = {
        name: '',
        query: '',
        threshold: 10,
        window_minutes: 5,
        notify_type: 'webhook',
        notify_target: ''
      };
    }
    showModal = true;
  }

  async function saveAlert() {
    if (!form.name) return;

    try {
      if (editingAlert) {
        await fetch(`${API_BASE}/alerts/${editingAlert.id}`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(form)
        });
      } else {
        await fetch(`${API_BASE}/alerts`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(form)
        });
      }
      showModal = false;
      await loadAlerts();
    } catch (err) {
      console.error('Failed to save alert:', err);
    }
  }

  async function toggleAlert(alert) {
    try {
      await fetch(`${API_BASE}/alerts/${alert.id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: alert.enabled ? 0 : 1 })
      });
      await loadAlerts();
    } catch (err) {
      console.error('Failed to toggle alert:', err);
    }
  }

  async function deleteAlert(id) {
    if (!confirm('Delete this alert?')) return;
    try {
      await fetch(`${API_BASE}/alerts/${id}`, { method: 'DELETE' });
      await loadAlerts();
    } catch (err) {
      console.error('Failed to delete alert:', err);
    }
  }

  function requestNotificationPermission() {
    if ('Notification' in window) {
      Notification.requestPermission();
    }
  }
</script>

<div class="alerts-panel">
  <div class="header">
    <h3>Alerts</h3>
    <button class="btn-icon" on:click={() => openModal()} title="Create alert">
      <svg width="14" height="14" viewBox="0 0 14 14">
        <path fill="currentColor" d="M7 1v12M1 7h12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
    </button>
  </div>

  {#if alerts.length === 0}
    <p class="empty">No alerts configured</p>
    <button class="btn-small" on:click={requestNotificationPermission}>
      Enable notifications
    </button>
  {:else}
    <ul>
      {#each alerts as alert}
        <li class:disabled={!alert.enabled}>
          <button class="alert-info" on:click={() => openModal(alert)}>
            <span class="name">{alert.name}</span>
            <span class="details">
              {alert.query || 'All logs'} >= {alert.threshold} in {alert.window_minutes}m
            </span>
          </button>
          <button class="btn-toggle" on:click|stopPropagation={() => toggleAlert(alert)} title={alert.enabled ? 'Disable' : 'Enable'}>
            {#if alert.enabled}
              <svg width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5" fill="#3fb950"/></svg>
            {:else}
              <svg width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5" fill="none" stroke="#6e7681" stroke-width="1.5"/></svg>
            {/if}
          </button>
          <button class="btn-delete" aria-label="Delete alert" on:click|stopPropagation={() => deleteAlert(alert.id)}>
            <svg width="12" height="12" viewBox="0 0 12 12">
              <path fill="currentColor" d="M9.5 3L3 9.5M3 3l6.5 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          </button>
        </li>
      {/each}
    </ul>
  {/if}
</div>

{#if showModal}
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <div class="modal-overlay" role="dialog" aria-modal="true" tabindex="-1" on:click={() => showModal = false} on:keydown={(e) => e.key === 'Escape' && (showModal = false)}>
    <!-- svelte-ignore a11y-no-noninteractive-element-interactions -->
    <div class="modal" role="document" on:click|stopPropagation on:keydown|stopPropagation>
      <h3>{editingAlert ? 'Edit Alert' : 'Create Alert'}</h3>

      <label>
        Name
        <input type="text" bind:value={form.name} placeholder="High error rate" />
      </label>

      <label>
        Query (optional)
        <input type="text" bind:value={form.query} placeholder="level:ERROR" />
      </label>

      <div class="row">
        <label>
          Threshold
          <input type="number" bind:value={form.threshold} min="1" />
        </label>
        <label>
          Window (minutes)
          <input type="number" bind:value={form.window_minutes} min="1" />
        </label>
      </div>

      <label>
        Notification Type
        <select bind:value={form.notify_type}>
          <option value="browser">Browser</option>
          <option value="webhook">Webhook</option>
          <option value="slack">Slack</option>
        </select>
      </label>

      {#if form.notify_type !== 'browser'}
        <label>
          {form.notify_type === 'slack' ? 'Slack Webhook URL' : 'Webhook URL'}
          <input type="url" bind:value={form.notify_target} placeholder="https://..." />
        </label>
      {/if}

      <div class="actions">
        <button class="btn" on:click={() => showModal = false}>Cancel</button>
        <button class="btn primary" on:click={saveAlert}>Save</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .alerts-panel {
    margin-top: 24px;
    padding-top: 16px;
    border-top: 1px solid #30363d;
  }

  .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }

  h3 {
    font-size: 12px;
    text-transform: uppercase;
    color: #8b949e;
    font-weight: 600;
  }

  .btn-icon {
    padding: 4px;
    background: none;
    border: none;
    color: #8b949e;
    cursor: pointer;
    border-radius: 4px;
  }

  .btn-icon:hover {
    color: #c9d1d9;
    background: #30363d;
  }

  .empty {
    color: #6e7681;
    font-size: 13px;
    margin-bottom: 8px;
  }

  .btn-small {
    padding: 4px 8px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #8b949e;
    cursor: pointer;
    font-size: 11px;
  }

  .btn-small:hover {
    color: #c9d1d9;
    background: #30363d;
  }

  ul {
    list-style: none;
  }

  li {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-bottom: 4px;
  }

  li.disabled {
    opacity: 0.5;
  }

  .alert-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    padding: 8px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    cursor: pointer;
  }

  .alert-info:hover {
    border-color: #58a6ff;
  }

  .name {
    color: #c9d1d9;
    font-size: 13px;
    font-weight: 500;
  }

  .details {
    color: #8b949e;
    font-size: 11px;
  }

  .btn-toggle, .btn-delete {
    padding: 4px;
    background: none;
    border: none;
    cursor: pointer;
    border-radius: 4px;
  }

  .btn-delete {
    color: #6e7681;
  }

  .btn-delete:hover {
    color: #f85149;
    background: rgba(248, 81, 73, 0.1);
  }

  .modal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .modal {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 20px;
    width: 450px;
  }

  .modal h3 {
    font-size: 16px;
    color: #c9d1d9;
    text-transform: none;
    margin-bottom: 16px;
  }

  label {
    display: block;
    margin-bottom: 12px;
    color: #8b949e;
    font-size: 12px;
  }

  .row {
    display: flex;
    gap: 12px;
  }

  .row label {
    flex: 1;
  }

  input, select {
    width: 100%;
    margin-top: 4px;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 14px;
  }

  input:focus, select:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 16px;
  }

  .btn {
    padding: 8px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 14px;
  }

  .btn:hover {
    background: #30363d;
  }

  .btn.primary {
    background: #238636;
    border-color: #238636;
  }

  .btn.primary:hover {
    background: #2ea043;
  }
</style>
