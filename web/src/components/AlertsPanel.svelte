<script>
  import { onMount, onDestroy } from 'svelte';
  import Modal from './ui/Modal.svelte';
  import ConfirmDialog from './ui/ConfirmDialog.svelte';
  import EmptyState from './ui/EmptyState.svelte';
  import { bell } from './ui/icons.js';
  import AlertTemplateGallery from './alerts/AlertTemplateGallery.svelte';
  import AlertsPanelHeader from './alerts/AlertsPanelHeader.svelte';
  import AlertList from './alerts/AlertList.svelte';
  import AlertFormModal from './alerts/AlertFormModal.svelte';
  import { k8sMode } from '../stores/auth.js';
  import { error as toastError, success as toastSuccess, warning as toastWarning } from '../stores/toast.js';
  import { api } from '../utils/api.js';

  // What GET /alerts last returned.
  let serverAlerts = $state([]);

  // Rows this panel created locally that the server list has not echoed back
  // yet. POST /alerts answers `{status:'ok'}` with no id, so an optimistic row
  // carries a temporary one and is matched back by its fields.
  let pendingAlerts = $state([]);
  let pendingSeq = 0;

  // How long an unconfirmed optimistic row may survive. Long enough to outlast
  // the 60s poll (so a slow server still gets to confirm it), short enough that
  // a write which silently did not persist cannot leave a permanent ghost.
  const PENDING_TTL_MS = 90000;

  // What the panel renders. Keeping this derived means every read path
  // (rendering, the trigger baseline, the 60s poll) sees the same list.
  const alerts = $derived([...serverAlerts, ...pendingAlerts]);

  let showModal = $state(false);
  let editingAlert = $state(null);
  let expanded = $state(false);

  let form = $state({
    name: '',
    query: '',
    threshold: 10,
    window_minutes: 5,
    notify_type: 'webhook',
    notify_target: ''
  });

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
  let showDeleteConfirm = $state(false);
  let deleteTargetId = null;

  // Template gallery state
  let showTemplateGallery = $state(false);

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
      // (e.g. a validation error) is the actionable part.
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

  function openModal(alert = null) {
    if (alert) {
      editingAlert = alert;
      form = {
        // `?? ''`: these feed bind:value on Input, whose $bindable fallback
        // throws if handed undefined (#85).
        name: alert.name ?? '',
        query: alert.query ?? '',
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
      // The server's own wording matters here — a validation rejection
      // ("Invalid threshold", ...) is actionable, and a generic message would
      // hide it behind something the user cannot act on.
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

  function handleUseTemplate(template) {
    showTemplateGallery = false;
    editingAlert = null;
    form = {
      name: template.name ?? '',
      query: template.query ?? '',
      threshold: template.threshold,
      window_minutes: template.window_minutes,
      notify_type: 'webhook',
      notify_target: ''
    };
    showModal = true;
  }
</script>

<div class="alerts-panel">
  <AlertsPanelHeader
    {expanded}
    count={alerts.length}
    ontoggle={() => expanded = !expanded}
    oncreate={() => openModal()}
    onbrowsetemplates={() => showTemplateGallery = true}
    onchecked={loadAlerts}
  />

  {#if expanded}
    <div class="content">
      {#if alerts.length === 0}
        <EmptyState icon={bell} title="No alerts configured" size="sm">
          Create an alert to get notified when a query crosses a threshold.
        </EmptyState>
      {:else}
        <AlertList
          {alerts}
          onedit={openModal}
          ontoggle={toggleAlert}
          ondelete={requestDeleteAlert}
        />
      {/if}
    </div>
  {/if}
</div>

<AlertFormModal
  bind:open={showModal}
  bind:form
  editing={!!editingAlert}
  {notifyOptions}
  onsave={saveAlert}
/>

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
    <AlertTemplateGallery onusetemplate={handleUseTemplate} />
  </Modal>
{/if}

<style>
  .alerts-panel {
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid var(--border-color);
  }

  .content {
    padding-left: 20px;
  }
</style>
