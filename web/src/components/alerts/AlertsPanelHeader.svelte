<!--
  AlertsPanelHeader
  The collapsible header of the sidebar alerts panel: title, alert count and
  the action buttons (Check now, K8s templates, Create). "Check now" runs a
  real server-side evaluation and reports triggered alerts as browser
  notifications; AlertsPanel owns the list and reloads it afterwards.
-->
<script>
  import Button from '../ui/Button.svelte';
  import Icon from '../ui/Icon.svelte';
  import { caretRight, refresh, gridSolid, plus } from '../ui/icons.js';
  import { k8sMode } from '../../stores/auth.js';
  import { error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import { stopPropagation } from '../../utils/dom.js';

  let {
    /** The panel body is open */
    expanded = false,
    /** Number of alerts shown in the badge (hidden when 0) */
    count = 0,
    /** () => void — header clicked or activated from the keyboard */
    ontoggle,
    /** () => void */
    oncreate,
    /** () => void — open the K8s template gallery */
    onbrowsetemplates,
    /** () => Promise<void> — reload the list after a manual check */
    onchecked,
  } = $props();

  let checking = $state(false);

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

  // Explicit user action, so a real evaluation (and its fan-out) is what the
  // operator asked for. Unlike AlertsPanel's 60s poll, this cannot duplicate
  // messages at scale — it only runs when someone clicks.
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
      await onchecked();
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
      ontoggle();
    }
  }
</script>

<div class="header" role="button" tabindex="0" onclick={ontoggle} onkeydown={handleHeaderKeydown}>
  <Icon icon={caretRight} size={12} class="chevron {expanded ? 'expanded' : ''}" />
  <h3>Alerts</h3>
  {#if count > 0}
    <span class="count">{count}</span>
  {/if}
  <!-- Two stacked ignores, not one comma list: the compiler accepts
       `a, b` but eslint-plugin-svelte 2.x reads it as one bogus code (#73). -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <span class="header-actions" onclick={stopPropagation()}>
    <Button
      icon
      size="sm"
      variant="ghost"
      onclick={handleCheckNow}
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
        onclick={onbrowsetemplates}
        title="Browse K8s Templates"
        aria-label="Browse K8s alert templates"
      >
        <Icon icon={gridSolid} size={14} />
      </Button>
    {/if}
    <Button icon size="sm" variant="ghost" onclick={() => oncreate()} title="Create alert" aria-label="Create alert">
      <Icon icon={plus} size={14} strokeWidth={2.5} />
    </Button>
  </span>
</div>

<style>
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
</style>
