<script>
  import { onMount, onDestroy } from 'svelte';
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import Select from './ui/Select.svelte';
  import Modal from './ui/Modal.svelte';
  import ConfirmDialog from './ui/ConfirmDialog.svelte';
  import AlertTemplateGallery from './alerts/AlertTemplateGallery.svelte';
  import { k8sMode } from '../stores/license.js';
  import { error as toastError } from '../stores/toast.js';
  import { api } from '../utils/api.js';

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
    { value: 'slack', label: 'Slack' },
    { value: 'telegram', label: 'Telegram' }
  ];

  let checkInterval;

  // Confirm dialog state
  let showDeleteConfirm = false;
  let deleteTargetId = null;

  // Template gallery state
  let showTemplateGallery = false;

  onMount(() => {
    loadAlerts();
    checkInterval = setInterval(checkAlerts, 60000);
  });

  onDestroy(() => {
    if (checkInterval) clearInterval(checkInterval);
  });

  async function loadAlerts() {
    try {
      const data = await api.get('/alerts');
      alerts = data.alerts || [];
    } catch (err) {
      console.error('Failed to load alerts:', err);
      toastError('Failed to load alerts');
    }
  }

  async function checkAlerts() {
    try {
      const data = await api.post('/alerts/check');
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
        await api.put(`/alerts/${editingAlert.id}`, form);
      } else {
        await api.post('/alerts', form);
      }
      showModal = false;
      await loadAlerts();
    } catch (err) {
      console.error('Failed to save alert:', err);
      toastError('Failed to save alert');
    }
  }

  async function toggleAlert(alert) {
    try {
      await api.put(`/alerts/${alert.id}`, { enabled: alert.enabled ? 0 : 1 });
      await loadAlerts();
    } catch (err) {
      console.error('Failed to toggle alert:', err);
    }
  }

  function requestDeleteAlert(id) {
    deleteTargetId = id;
    showDeleteConfirm = true;
  }

  async function confirmDeleteAlert() {
    if (!deleteTargetId) return;
    try {
      await api.del(`/alerts/${deleteTargetId}`);
      await loadAlerts();
    } catch (err) {
      console.error('Failed to delete alert:', err);
    }
    deleteTargetId = null;
  }

  let checking = false;

  async function handleCheckNow() {
    checking = true;
    try {
      await checkAlerts();
    } finally {
      checking = false;
    }
  }

  function handleHeaderKeydown(e) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      expanded = !expanded;
    }
  }

  function handleUseTemplate(event) {
    const template = event.detail;
    showTemplateGallery = false;
    editingAlert = null;
    form = {
      name: template.name,
      query: template.query,
      threshold: template.threshold,
      window_minutes: template.window_minutes,
      notify_type: 'webhook',
      notify_target: ''
    };
    showModal = true;
  }
</script>

<div class="alerts-panel">
  <!-- svelte-ignore a11y-no-static-element-interactions -->
  <div class="header" role="button" tabindex="0" on:click={() => expanded = !expanded} on:keydown={handleHeaderKeydown}>
    <svg class="chevron" class:expanded width="12" height="12" viewBox="0 0 12 12">
      <path fill="currentColor" d="M4 2l4 4-4 4"/>
    </svg>
    <h3>Alerts</h3>
    {#if alerts.length > 0}
      <span class="count">{alerts.length}</span>
    {/if}
    <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
    <span class="header-actions" on:click|stopPropagation>
      <Button icon size="sm" variant="ghost" on:click={handleCheckNow} title="Check alerts now" disabled={checking}>
        <svg class:spinning={checking} width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M23 4v6h-6M1 20v-6h6"/>
          <path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
        </svg>
      </Button>
      {#if $k8sMode}
        <Button icon size="sm" variant="ghost" on:click={() => showTemplateGallery = true} title="Browse K8s Templates">
          <svg width="14" height="14" viewBox="0 0 14 14">
            <rect x="1" y="1" width="5" height="5" rx="1" fill="currentColor"/>
            <rect x="8" y="1" width="5" height="5" rx="1" fill="currentColor"/>
            <rect x="1" y="8" width="5" height="5" rx="1" fill="currentColor"/>
            <rect x="8" y="8" width="5" height="5" rx="1" fill="currentColor"/>
          </svg>
        </Button>
      {/if}
      <Button icon size="sm" variant="ghost" on:click={() => openModal()} title="Create alert">
        <svg width="14" height="14" viewBox="0 0 14 14">
          <path fill="currentColor" d="M7 1v12M1 7h12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
        </svg>
      </Button>
    </span>
  </div>

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
              <Button icon size="sm" variant="ghost" on:click={() => requestDeleteAlert(alert.id)} class="delete-btn">
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

    {#if form.notify_type === 'webhook'}
      <Input
        label="Webhook URL"
        type="url"
        bind:value={form.notify_target}
        placeholder="https://..."
        fullWidth
      />
    {:else if form.notify_type === 'slack'}
      <Input
        label="Slack Webhook URL"
        type="url"
        bind:value={form.notify_target}
        placeholder="https://hooks.slack.com/services/..."
        fullWidth
      />
    {:else if form.notify_type === 'telegram'}
      <div class="notify-info">
        Telegram bot token and chat ID are configured via server environment variables
        (<code>PURL_TELEGRAM_BOT_TOKEN</code>, <code>PURL_TELEGRAM_CHAT_ID</code>).
      </div>
    {/if}
  </div>

  <svelte:fragment slot="footer">
    <Button variant="default" on:click={() => showModal = false}>Cancel</Button>
    <Button variant="success" on:click={saveAlert}>Save</Button>
  </svelte:fragment>
</Modal>

<ConfirmDialog
  bind:show={showDeleteConfirm}
  title="Delete Alert"
  message="Are you sure you want to delete this alert? This action cannot be undone."
  confirmText="Delete"
  variant="danger"
  onConfirm={confirmDeleteAlert}
/>

{#if $k8sMode}
  <Modal bind:open={showTemplateGallery} title="K8s Alert Templates" size="lg">
    <AlertTemplateGallery on:use-template={handleUseTemplate} />
  </Modal>
{/if}

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
    user-select: none;
  }

  .header-actions {
    display: flex;
    align-items: center;
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

  .notify-info {
    padding: 10px 12px;
    background: rgba(88, 166, 255, 0.08);
    border: 1px solid rgba(88, 166, 255, 0.2);
    border-radius: 6px;
    font-size: 12px;
    color: var(--text-secondary, #8b949e);
    line-height: 1.5;
  }

  .spinning {
    animation: spin 1s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .notify-info code {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 11px;
    color: var(--color-primary, #58a6ff);
    background: rgba(88, 166, 255, 0.1);
    padding: 1px 4px;
    border-radius: 3px;
  }
</style>
