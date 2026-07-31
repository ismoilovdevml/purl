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
  import { error as toastError, success as toastSuccess, warning as toastWarning } from '../stores/toast.js';
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

  // "Browser" is deliberately absent: the backend coerces every notify_type
  // outside telegram|slack|webhook into `webhook`, so an alert saved as
  // "browser" is delivered through the webhook branch with an empty target —
  // i.e. nowhere, while the user is told it was created (issue #38). The
  // option comes back when the backend accepts `browser` end to end.
  const notifyOptions = [
    { value: 'webhook', label: 'Webhook' },
    { value: 'slack', label: 'Slack' },
    { value: 'telegram', label: 'Telegram' }
  ];

  /**
   * Coerce a stored notify_type onto one of the three options above. Rows
   * written before "browser" was removed still carry it, and opening one used
   * to render an empty <Select> with no target field at all — no way to see or
   * repair the alert. `webhook` is the honest default: it is what the backend
   * already coerces every unknown type to when the alert fires.
   */
  function normalizeNotifyType(value) {
    return notifyOptions.some((o) => o.value === value) ? value : 'webhook';
  }

  let checkInterval;

  // Confirm dialog state
  let showDeleteConfirm = false;
  let deleteTargetId = null;

  // Template gallery state
  let showTemplateGallery = false;

  onMount(async () => {
    await loadAlerts();
    // Evaluation is the server's job — a leader-elected timer runs
    // check_alerts() and fans out to Telegram/Slack/webhook. This panel must
    // NOT call POST /alerts/check on a timer: that endpoint sends
    // notifications, so with the server timer also running, every open
    // dashboard tab would multiply every message. Here we only READ.
    checkInterval = setInterval(loadAlerts, 60000);
  });

  onDestroy(() => {
    if (checkInterval) clearInterval(checkInterval);
  });

  // Monotonic id for GET /alerts. Three callers can be in flight at once (the
  // 60s poll, reconcileAlerts, every write path), and responses can land out of
  // order: a poll issued BEFORE a create can resolve after the reconcile that
  // already confirmed it. Unconditionally assigning `serverAlerts` there
  // restores the pre-write list and the new alert vanishes for up to a minute,
  // while the green "created" toast is still on screen. Only the newest request
  // is allowed to write. (Same "latest wins" rule as the search path in
  // stores/logs.js, which enforces it with an AbortController.)
  let loadSeq = 0;

  async function loadAlerts() {
    const seq = ++loadSeq;
    try {
      const data = await api.get('/alerts');
      if (seq !== loadSeq) return;
      serverAlerts = data.alerts || [];
      // Confirmed: the server now knows about this row, so the optimistic copy
      // has done its job and disappears silently.
      pendingAlerts = pendingAlerts.filter((p) => !serverAlerts.some((s) => isSameAlert(s, p)));
    } catch (err) {
      if (seq !== loadSeq) return;
      console.error('Failed to load alerts:', err);
      // Prefixed because this one fires from the background poll: on its own,
      // "Network error - could not reach the server" gives the user no idea
      // what the dashboard was doing. The write paths below stay unprefixed —
      // there the user just clicked something and the server's own wording
      // (e.g. a plan limit) is the actionable part.
      toastError('Failed to load alerts: ' + (err.message || 'Unknown error'));
    } finally {
      // In `finally`, not in the `try`: the case the TTL exists for is exactly
      // the one where this reload failed (server down, network gone). Sweeping
      // only on the success path would leave the dashed ghost row on screen
      // for as long as the panel stays open. Superseded requests skip it — the
      // one that overtook them owns the sweep.
      if (seq === loadSeq) sweepExpiredPending();
    }
  }

  /**
   * Drop optimistic rows the server never echoed back — and say so. Expiry is
   * NOT the same event as confirmation: the write announced itself with a
   * success toast, so if the row never turns up, the user has to hear about it
   * rather than watch it quietly vanish.
   *
   * The wording is deliberately NOT "was not saved". A pending row only exists
   * after POST /alerts already answered 2xx, so the write almost certainly did
   * persist; what failed is the read-back (server unreachable for 90s, or a
   * value the backend rewrote on the way in). Claiming it was not saved makes
   * the user create the alert a second time — a real duplicate, and duplicate
   * Telegram/Slack messages from then on. All the client actually knows is that
   * it could not confirm.
   */
  function sweepExpiredPending() {
    if (pendingAlerts.length === 0) return;

    const now = Date.now();
    const expired = pendingAlerts.filter((p) => now - p.createdAt >= PENDING_TTL_MS);
    if (expired.length === 0) return;

    pendingAlerts = pendingAlerts.filter((p) => now - p.createdAt < PENDING_TTL_MS);
    for (const alert of expired) {
      toastWarning(`Could not confirm alert "${alert.name}" — reload to check whether it exists.`);
    }
  }

  /**
   * Does this server row correspond to a locally created one? Needed because
   * POST /alerts answers `{status:'ok'}` with no id, so there is nothing else
   * to join on.
   *
   * Only `name` and `query` are compared — the fields the backend stores
   * verbatim. `threshold` and `window_minutes` are NOT usable here:
   * Storage/ClickHouse/Alerts.pm clamps them (1..1000000 and 1..1440) instead
   * of rejecting, so a window of 2000 is stored as 1440 and a join on it never
   * matches. The row then rendered twice for 90s (real + dashed ghost) and the
   * expiry toast fired on an alert that was saved perfectly well.
   *
   * The looser join can confirm a pending row against a pre-existing alert with
   * the same name and query. That is the better failure: the two are
   * indistinguishable to the user anyway, and the outcome is a missing dashed
   * outline for a few seconds instead of a false "not saved" claim. The real
   * fix is for POST /alerts to return the created row — see the report.
   */
  function isSameAlert(serverAlert, draft) {
    return serverAlert.name === draft.name
      && (serverAlert.query || '') === (draft.query || '');
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

  /**
   * Feedback for an explicit "Check now": the evaluation the operator just
   * asked for is reported in the browser as well as through the alert's own
   * channel. There is deliberately no passive notify-on-poll path — it keyed
   * off `notify_type === 'browser'`, which the backend never persists
   * (issue #38), so it was dead code pretending to be a delivery channel.
   *
   * Nothing in the app ever called Notification.requestPermission(), so the
   * default 'default' permission made this return early every time and the
   * whole path was dead code. The ask now happens in handleCheckNow, where a
   * click is what triggers it — browsers reject the prompt outside a user
   * gesture, and prompting on page load is what gets a site permanently
   * blocked.
   */
  async function requestNotificationPermission() {
    if (!('Notification' in window)) return;
    if (Notification.permission !== 'default') return;
    try {
      await Notification.requestPermission();
    } catch {
      // Older browsers expose only the callback form, and a rejected prompt is
      // not an error worth surfacing. Either way notifications stay off.
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
        notify_type: normalizeNotifyType(alert.notify_type),
        notify_target: alert.notify_target || ''
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
      // The server's own wording matters here — the likeliest rejection is a
      // plan limit ("Alert limit reached for your plan (3)"), which a generic
      // message would hide behind something the user cannot act on.
      toastError(err.message || 'Failed to save alert');
    }
  }

  async function toggleAlert(alert) {
    try {
      await api.put(`/alerts/${alert.id}`, { enabled: alert.enabled ? 0 : 1 });
      await loadAlerts();
    } catch (err) {
      console.error('Failed to toggle alert:', err);
      toastError(err.message || `Failed to ${alert.enabled ? 'disable' : 'enable'} alert`);
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
      toastError(err.message || 'Failed to delete alert');
    }
    deleteTargetId = null;
  }

  let checking = false;

  // Explicit user action, so a real evaluation (and its fan-out) is what the
  // operator asked for. Unlike the timer above, this cannot duplicate messages
  // at scale — it only runs when someone clicks.
  async function handleCheckNow() {
    checking = true;
    // Asked for here and nowhere else: this is the only click that can produce
    // a browser notification, and the prompt needs a user gesture. Awaited
    // before the check so a first-time "Allow" still applies to this run's
    // results. Failure is silent — a denied or dismissed prompt just means
    // showNotification() stays a no-op, which is its documented behaviour.
    await requestNotificationPermission();
    try {
      const data = await api.post('/alerts/check');
      for (const alert of data.triggered || []) {
        showNotification(alert);
      }
      await loadAlerts();
    } catch (err) {
      console.error('Alert check failed:', err);
      toastError(err.message || 'Alert check failed');
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
    border-top: 1px solid var(--border-color);
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
    color: var(--text-primary);
  }

  /* :global — the class is forwarded onto the SVG that Icon renders. */
  .header :global(.chevron) {
    color: var(--text-secondary);
    transition: transform 0.15s ease;
  }

  .header :global(.chevron.expanded) {
    transform: rotate(90deg);
  }

  h3 {
    flex: 1;
    font-size: 11px;
    text-transform: uppercase;
    color: var(--text-secondary);
    font-weight: 600;
    margin: 0;
    transition: color 0.15s;
  }

  .count {
    font-size: 10px;
    color: var(--text-muted);
    background: var(--bg-tertiary);
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
    border-color: var(--color-primary);
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
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    cursor: pointer;
    text-align: left;
  }

  .alert-info:hover {
    border-color: var(--color-primary);
  }

  .name {
    color: var(--text-primary);
    font-size: 13px;
    font-weight: 500;
  }

  .details {
    color: var(--text-secondary);
    font-size: 11px;
  }

  :global(.delete-btn):hover {
    color: var(--color-error) !important;
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
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .notify-info code {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-primary);
    background: rgba(88, 166, 255, 0.1);
    padding: 1px 4px;
    border-radius: 3px;
  }
</style>
