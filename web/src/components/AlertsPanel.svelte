<script>
  import { onMount, onDestroy } from 'svelte';
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import Select from './ui/Select.svelte';
  import Modal from './ui/Modal.svelte';

  let alerts = [];
  let showModal = false;
  let editingAlert = null;
  let expanded = false;

  let form = {
    name: '',
    query: '',
    threshold: 10,
    window_minutes: 5,
    notify_type: 'webhook',
    notify_target: ''
  };

  const notifyOptions = [
    { value: 'browser', label: 'Browser' },
    { value: 'webhook', label: 'Webhook' },
    { value: 'slack', label: 'Slack' }
  ];

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

  function handleAddClick(e) {
    e.stopPropagation();
    openModal();
  }
</script>

<div class="alerts-panel">
  <button class="header" on:click={() => expanded = !expanded}>
    <svg class="chevron" class:expanded width="12" height="12" viewBox="0 0 12 12">
      <path fill="currentColor" d="M4 2l4 4-4 4"/>
    </svg>
    <h3>Alerts</h3>
    {#if alerts.length > 0}
      <span class="count">{alerts.length}</span>
    {/if}
    <Button icon size="sm" variant="ghost" on:click={handleAddClick} title="Create alert">
      <svg width="14" height="14" viewBox="0 0 14 14">
        <path fill="currentColor" d="M7 1v12M1 7h12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
    </Button>
  </button>

  {#if expanded}
    <div class="content">
      {#if alerts.length === 0}
        <p class="empty">No alerts configured</p>
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
              <Button icon size="sm" variant="ghost" on:click={() => toggleAlert(alert)} title={alert.enabled ? 'Disable' : 'Enable'}>
                {#if alert.enabled}
                  <svg width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5" fill="#3fb950"/></svg>
                {:else}
                  <svg width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5" fill="none" stroke="#6e7681" stroke-width="1.5"/></svg>
                {/if}
              </Button>
              <Button icon size="sm" variant="ghost" on:click={() => deleteAlert(alert.id)} class="delete-btn">
                <svg width="12" height="12" viewBox="0 0 12 12">
                  <path fill="currentColor" d="M9.5 3L3 9.5M3 3l6.5 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                </svg>
              </Button>
            </li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}
</div>

<Modal bind:open={showModal} title={editingAlert ? 'Edit Alert' : 'Create Alert'} size="md">
  <div class="form-content">
    <Input
      label="Name"
      bind:value={form.name}
      placeholder="High error rate"
      fullWidth
    />

    <Input
      label="Query (optional)"
      bind:value={form.query}
      placeholder="level:ERROR"
      fullWidth
    />

    <div class="row">
      <Input
        label="Threshold"
        type="number"
        bind:value={form.threshold}
        min={1}
      />
      <Input
        label="Window (minutes)"
        type="number"
        bind:value={form.window_minutes}
        min={1}
      />
    </div>

    <Select
      label="Notification Type"
      bind:value={form.notify_type}
      options={notifyOptions}
      fullWidth
    />

    {#if form.notify_type !== 'browser'}
      <Input
        label={form.notify_type === 'slack' ? 'Slack Webhook URL' : 'Webhook URL'}
        type="url"
        bind:value={form.notify_target}
        placeholder="https://..."
        fullWidth
      />
    {/if}
  </div>

  <svelte:fragment slot="footer">
    <Button variant="default" on:click={() => showModal = false}>Cancel</Button>
    <Button variant="success" on:click={saveAlert}>Save</Button>
  </svelte:fragment>
</Modal>

<style>
  .alerts-panel {
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid var(--border-color, #30363d);
  }

  .header {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px 0;
    background: none;
    border: none;
    cursor: pointer;
    text-align: left;
  }

  .header:hover h3 {
    color: var(--text-primary, #c9d1d9);
  }

  .chevron {
    color: var(--text-secondary, #8b949e);
    transition: transform 0.15s ease;
  }

  .chevron.expanded {
    transform: rotate(90deg);
  }

  h3 {
    flex: 1;
    font-size: 11px;
    text-transform: uppercase;
    color: var(--text-secondary, #8b949e);
    font-weight: 600;
    margin: 0;
    transition: color 0.15s;
  }

  .count {
    font-size: 10px;
    color: var(--text-muted, #6e7681);
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 10px;
  }

  .content {
    padding-left: 20px;
  }

  .empty {
    color: var(--text-muted, #6e7681);
    font-size: 12px;
    margin: 0;
    padding: 8px 0;
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
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    cursor: pointer;
    text-align: left;
  }

  .alert-info:hover {
    border-color: var(--color-primary, #58a6ff);
  }

  .name {
    color: var(--text-primary, #c9d1d9);
    font-size: 13px;
    font-weight: 500;
  }

  .details {
    color: var(--text-secondary, #8b949e);
    font-size: 11px;
  }

  :global(.delete-btn):hover {
    color: var(--color-error, #f85149) !important;
  }

  .form-content {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .row {
    display: flex;
    gap: 12px;
  }

  .row > :global(*) {
    flex: 1;
  }
</style>
