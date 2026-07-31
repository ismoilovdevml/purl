<script>
  import { onMount, onDestroy } from 'svelte';
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import Select from './ui/Select.svelte';
  import Modal from './ui/Modal.svelte';
  import ConfirmDialog from './ui/ConfirmDialog.svelte';
  import EmptyState from './ui/EmptyState.svelte';
  import Icon from './ui/Icon.svelte';
  import { caretRight, refresh, gridSolid, plus, dot, dotOutline, close, bell } from './ui/icons.js';
  import AlertTemplateGallery from './alerts/AlertTemplateGallery.svelte';
  import { k8sMode } from '../stores/license.js';
  import { error as toastError, success as toastSuccess } from '../stores/toast.js';
  import { api } from '../utils/api.js';

  // What GET /alerts last returned.
  let serverAlerts = [];

  // Rows this panel created locally that the server list has not echoed back
  // yet. POST /alerts answers `{status:'ok'}` with no id, so an optimistic row
  // carries a temporary one and is matched back by its fields.
  let pendingAlerts = [];
  let pendingSeq = 0;

  // How long an unconfirmed optimistic row may survive. Long enough to outlast
  // the 60s poll (so a slow server still gets to confirm it), short enough that
  // a write which silently did not persist cannot leave a permanent ghost.
  const PENDING_TTL_MS = 90000;

  // What the panel renders. Keeping this derived means every read path
  // (rendering, the trigger baseline, the 60s poll) sees the same list.
  $: alerts = [...serverAlerts, ...pendingAlerts];

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

  onMount(async () => {
    // Seed the baseline BEFORE polling starts, otherwise every alert that has
    // ever fired would pop a browser notification the moment the panel mounts.
    await loadAlerts();
    seedTriggeredBaseline();
    checkInterval = setInterval(refreshAndNotify, 60000);
  });

  onDestroy(() => {
    if (checkInterval) clearInterval(checkInterval);
  });

  async function loadAlerts() {
    try {
      const data = await api.get('/alerts');
      serverAlerts = data.alerts || [];
      // Drop an optimistic row once the server knows about it — or once it has
      // outlived its TTL, so nothing can linger indefinitely.
      const now = Date.now();
      pendingAlerts = pendingAlerts.filter(
        (p) => !serverAlerts.some((s) => isSameAlert(s, p)) && now - p.createdAt < PENDING_TTL_MS
      );
    } catch (err) {
      console.error('Failed to load alerts:', err);
      toastError('Failed to load alerts');
    }
  }

  /**
   * Does this server row correspond to a locally created one? Needed because
   * POST /alerts does not return the new id, so there is nothing else to join on.
   */
  function isSameAlert(serverAlert, draft) {
    return serverAlert.name === draft.name
      && (serverAlert.query || '') === (draft.query || '')
      && Number(serverAlert.threshold) === Number(draft.threshold)
      && Number(serverAlert.window_minutes) === Number(draft.window_minutes);
  }

  /**
   * Reload after a write, tolerating the moment it takes for the new row to
   * become visible (network latency; historically also a read-after-write
   * window on the server, fixed separately).
   *
   * Exactly ONE extra attempt — deliberately not a poll loop. The optimistic
   * row keeps the panel honest in the meantime, and its TTL (not this function)
   * is what guarantees it cannot linger.
   */
  async function reconcileAlerts() {
    await loadAlerts();
    if (pendingAlerts.length === 0) return;
    await new Promise((resolve) => setTimeout(resolve, 1000));
    await loadAlerts();
  }

  // Last `last_triggered` value we have already notified about, per alert id.
  let seenTriggered = new Map();

  function seedTriggeredBaseline() {
    seenTriggered = new Map(alerts.map((a) => [a.id, a.last_triggered]));
  }

  // Evaluation is the server's job — a leader-elected timer runs check_alerts()
  // and fans out to Telegram/Slack/webhook. This panel must NOT call
  // POST /alerts/check on a timer: that endpoint sends notifications, so with
  // the server timer also running, every open dashboard tab multiplied every
  // message. Here we only READ, and raise the one channel the server cannot
  // reach — the browser notification — when an alert's last_triggered advances.
  async function refreshAndNotify() {
    try {
      await loadAlerts();
    } catch {
      return; // loadAlerts already surfaced the error
    }

    for (const alert of alerts) {
      const previous = seenTriggered.get(alert.id);
      const current = alert.last_triggered;
      if (!current || current === previous) continue;

      seenTriggered.set(alert.id, current);
      // Only alerts routed to "browser" have no server-side delivery path.
      if (previous !== undefined && alert.notify_type === 'browser') {
        showNotification(alert);
      }
    }
  }

  function showNotification(alert) {
    if (!('Notification' in window) || Notification.permission !== 'granted') return;

    // `count` is only present on a POST /alerts/check result. When the trigger
    // is observed via GET /alerts we know it fired but not by how much.
    const body =
      alert.count == null
        ? `Threshold of ${alert.threshold} reached for "${alert.query}"`
        : `${alert.count} logs matched "${alert.query}"`;

    new Notification(`Alert: ${alert.name}`, { body, icon: '/favicon.ico' });
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

    // Snapshot: `form` is rebound by openModal(), so the in-flight write must
    // not read it again once the modal closes.
    const draft = { ...form };
    const target = editingAlert;

    try {
      if (target) {
        await api.put(`/alerts/${target.id}`, draft);
        // Show the edit right away; the reload below replaces it with the
        // server's own copy.
        serverAlerts = serverAlerts.map((a) => (a.id === target.id ? { ...a, ...draft } : a));
      } else {
        await api.post('/alerts', draft);
        pendingAlerts = [
          ...pendingAlerts,
          {
            ...draft,
            id: `pending-${++pendingSeq}`,
            enabled: 1,
            last_triggered: null,
            pending: true,
            createdAt: Date.now(),
          },
        ];
        // A brand new row is invisible feedback inside a collapsed panel.
        expanded = true;
      }

      showModal = false;
      toastSuccess(target ? `Alert "${draft.name}" updated` : `Alert "${draft.name}" created`);
      await reconcileAlerts();
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

  // Explicit user action, so a real evaluation (and its fan-out) is what the
  // operator asked for. Unlike the timer above, this cannot duplicate messages
  // at scale — it only runs when someone clicks.
  async function handleCheckNow() {
    checking = true;
    try {
      const data = await api.post('/alerts/check');
      for (const alert of data.triggered || []) {
        showNotification(alert);
      }
      await loadAlerts();
      seedTriggeredBaseline();
    } catch (err) {
      console.error('Alert check failed:', err);
      toastError('Alert check failed');
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
    <Icon icon={caretRight} size={12} class="chevron {expanded ? 'expanded' : ''}" />
    <h3>Alerts</h3>
    {#if alerts.length > 0}
      <span class="count">{alerts.length}</span>
    {/if}
    <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
    <span class="header-actions" on:click|stopPropagation>
      <Button
        icon
        size="sm"
        variant="ghost"
        on:click={handleCheckNow}
        title="Check alerts now"
        aria-label="Check alerts now"
        disabled={checking}
      >
        <Icon icon={refresh} size={14} strokeWidth={2.5} spin={checking} />
      </Button>
      {#if $k8sMode}
        <Button
          icon
          size="sm"
          variant="ghost"
          on:click={() => showTemplateGallery = true}
          title="Browse K8s Templates"
          aria-label="Browse K8s alert templates"
        >
          <Icon icon={gridSolid} size={14} />
        </Button>
      {/if}
      <Button icon size="sm" variant="ghost" on:click={() => openModal()} title="Create alert" aria-label="Create alert">
        <Icon icon={plus} size={14} strokeWidth={2.5} />
      </Button>
    </span>
  </div>

  {#if expanded}
    <div class="content">
      {#if alerts.length === 0}
        <EmptyState icon={bell} title="No alerts configured" size="sm">
          Create an alert to get notified when a query crosses a threshold.
        </EmptyState>
      {:else}
        <ul>
          {#each alerts as alert (alert.id)}
            <!-- A pending row is shown for feedback but carries a placeholder
                 id, so every action that needs the real one stays disabled
                 until the server list confirms it. -->
            <li class:disabled={!alert.enabled} class:pending={alert.pending}>
              <button class="alert-info" on:click={() => openModal(alert)} disabled={alert.pending}>
                <span class="name">{alert.name}</span>
                <span class="details">
                  {alert.query || 'All logs'} >= {alert.threshold} in {alert.window_minutes}m
                </span>
              </button>
              <Button
                icon
                size="sm"
                variant="ghost"
                on:click={() => toggleAlert(alert)}
                title={alert.enabled ? 'Disable' : 'Enable'}
                aria-label="{alert.enabled ? 'Disable' : 'Enable'} alert {alert.name}"
                disabled={alert.pending}
              >
                {#if alert.enabled}
                  <Icon icon={dot} size={14} color="#3fb950" />
                {:else}
                  <Icon icon={dotOutline} size={14} strokeWidth={2.5} color="#848d97" />
                {/if}
              </Button>
              <Button
                icon
                size="sm"
                variant="ghost"
                on:click={() => requestDeleteAlert(alert.id)}
                title="Delete alert"
                aria-label="Delete alert {alert.name}"
                class="delete-btn"
                disabled={alert.pending}
              >
                <Icon icon={close} size={12} strokeWidth={3} />
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

  /* :global — the class is forwarded onto the SVG that Icon renders. */
  .header :global(.chevron) {
    color: var(--text-secondary, #8b949e);
    transition: transform 0.15s ease;
  }

  .header :global(.chevron.expanded) {
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
    color: var(--text-muted, #848d97);
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 10px;
  }

  .content {
    padding-left: 20px;
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

  /* Optimistic row: visible immediately, but visibly not settled yet. */
  li.pending .alert-info {
    border-style: dashed;
    border-color: var(--color-primary, #58a6ff);
    cursor: default;
  }

  li.pending {
    opacity: 0.7;
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

  .notify-info code {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 11px;
    color: var(--color-primary, #58a6ff);
    background: rgba(88, 166, 255, 0.1);
    padding: 1px 4px;
    border-radius: 3px;
  }
</style>
