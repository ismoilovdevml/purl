<script>
  import { onMount, onDestroy } from 'svelte';
  import {
    fetchAlerts,
    createAlert,
    updateAlert,
    deleteAlert as apiDeleteAlert,
    toggleAlertEnabled,
    checkAlerts as apiCheckAlerts
  } from '../lib/api.js';
  import Modal from './ui/Modal.svelte';
  import Button from './ui/Button.svelte';

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

  let checkInterval;

  onMount(() => {
    loadAlerts();
    checkInterval = setInterval(runAlertCheck, 60000);
  });

  onDestroy(() => {
    if (checkInterval) clearInterval(checkInterval);
  });

  async function loadAlerts() {
    try {
      const data = await fetchAlerts();
      alerts = data.alerts || [];
    } catch (err) {
      console.error('Failed to load alerts:', err);
    }
  }

  async function runAlertCheck() {
    try {
      const data = await apiCheckAlerts();
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

  function closeModal() {
    showModal = false;
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

  async function saveAlert() {
    if (!form.name) return;

    try {
      if (editingAlert) {
        await updateAlert(editingAlert.id, form);
      } else {
        await createAlert(form);
      }
      closeModal();
      await loadAlerts();
    } catch (err) {
      console.error('Failed to save alert:', err);
    }
  }

  async function toggleAlert(alert) {
    try {
      await toggleAlertEnabled(alert.id, alert.enabled ? 0 : 1);
      await loadAlerts();
    } catch (err) {
      console.error('Failed to toggle alert:', err);
    }
  }

  async function handleDelete(id) {
    if (!confirm('Delete this alert?')) return;
    try {
      await apiDeleteAlert(id);
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
          <button class="btn-delete" aria-label="Delete alert" on:click|stopPropagation={() => handleDelete(alert.id)}>
            <svg width="12" height="12" viewBox="0 0 12 12">
              <path fill="currentColor" d="M9.5 3L3 9.5M3 3l6.5 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          </button>
        </li>
      {/each}
    </ul>
  {/if}
</div>

<Modal show={showModal} title={editingAlert ? 'Edit Alert' : 'Create Alert'} width="450px" on:close={closeModal}>
  <div class="form-group">
    <label for="alert-name">Name</label>
    <input id="alert-name" type="text" bind:value={form.name} placeholder="High error rate" />
  </div>

  <div class="form-group">
    <label for="alert-query">Query (optional)</label>
    <input id="alert-query" type="text" bind:value={form.query} placeholder="level:ERROR" />
  </div>

  <div class="form-row">
    <div class="form-group">
      <label for="alert-threshold">Threshold</label>
      <input id="alert-threshold" type="number" bind:value={form.threshold} min="1" />
    </div>
    <div class="form-group">
      <label for="alert-window">Window (minutes)</label>
      <input id="alert-window" type="number" bind:value={form.window_minutes} min="1" />
    </div>
  </div>

  <div class="form-group">
    <label for="alert-notify-type">Notification Type</label>
    <select id="alert-notify-type" bind:value={form.notify_type}>
      <option value="browser">Browser</option>
      <option value="webhook">Webhook</option>
      <option value="slack">Slack</option>
    </select>
  </div>

  {#if form.notify_type !== 'browser'}
    <div class="form-group">
      <label for="alert-notify-target">{form.notify_type === 'slack' ? 'Slack Webhook URL' : 'Webhook URL'}</label>
      <input id="alert-notify-target" type="url" bind:value={form.notify_target} placeholder="https://..." />
    </div>
  {/if}

  <svelte:fragment slot="footer">
    <Button on:click={closeModal}>Cancel</Button>
    <Button variant="primary" on:click={saveAlert}>Save</Button>
  </svelte:fragment>
</Modal>

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
    text-align: left;
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

  /* Form styles */
  .form-group {
    margin-bottom: 16px;
  }

  .form-group label {
    display: block;
    margin-bottom: 6px;
    color: #8b949e;
    font-size: 12px;
    font-weight: 500;
  }

  .form-group input,
  .form-group select {
    width: 100%;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 14px;
  }

  .form-group input:focus,
  .form-group select:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .form-row {
    display: flex;
    gap: 12px;
  }

  .form-row .form-group {
    flex: 1;
  }
</style>
