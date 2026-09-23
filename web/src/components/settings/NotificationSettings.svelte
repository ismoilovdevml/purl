<!--
  NotificationSettings Component
  Telegram, Slack, and Webhook notification configuration

  Usage:
  <NotificationSettings />
-->
<script>
  import { onMount } from 'svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import ClearSecretConfirm from '../ui/ClearSecretConfirm.svelte';
  import NotificationChannelCard from './notifications/NotificationChannelCard.svelte';
  import NotificationFieldRow from './notifications/NotificationFieldRow.svelte';
  import NotificationStorageInfo from './notifications/NotificationStorageInfo.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import { isEnvLocked } from '../../utils/envLock.js';
  import { clearFlags, describeCleared } from '../../utils/clearSecret.js';
  import { telegram, slack, link } from '../ui/icons.js';

  let serverSettings = $state(null);
  let loadingSettings = $state(true);

  let notifications = $state({
    telegram: { enabled: false, bot_token: '', chat_id: '', thread_id: '' },
    slack: { enabled: false, webhook_url: '', channel: '' },
    webhook: { enabled: false, url: '', auth_token: '' }
  });

  /*
   * Per-key truth, keyed by the dotted name inside the notifications section
   * ('telegram.chat_id', 'slack.channel', 'webhook.auth_token', ...).
   *
   * The per-channel `from_env` flags below it only track each channel's
   * bot_token/webhook_url, so a chat_id or channel pinned by its OWN variable
   * rendered editable and 409'd on save. Both are consulted; neither replaces
   * the other.
   */
  const envKeys = $derived(serverSettings?.notifications?.from_env_keys);

  /*
   * The write-only secrets of each channel, and how GET /settings reports that
   * one is STORED. The flag names do not follow the field names (the server
   * answers `bot_token: 0|1` for telegram but `webhook_set` for slack), and a
   * secret nobody saved has nothing to remove — so the removal control is
   * driven by this lookup, not by the field list.
   *
   * webhook.auth_token is deliberately here with no flag: the endpoint accepts
   * clear_auth_token, but GET reports no auth_token_set, so its control stays
   * hidden until the backend ships one. Wrong-but-visible would mean offering
   * to delete a secret that may not exist.
   */
  const CHANNEL_SECRETS = {
    telegram: ['bot_token', 'chat_id'],
    slack: ['webhook_url'],
    webhook: ['url', 'auth_token'],
  };

  function storedSecretsFrom(settings) {
    const n = settings?.notifications;
    return {
      'telegram.bot_token': !!n?.telegram?.bot_token,
      'telegram.chat_id': !!n?.telegram?.chat_id,
      'slack.webhook_url': !!n?.slack?.webhook_set,
      'webhook.url': !!n?.webhook?.url_set,
      'webhook.auth_token': !!n?.webhook?.auth_token_set,
    };
  }

  const storedSecrets = $derived(storedSecretsFrom(serverSettings));

  /**
   * Fill the form from what the server actually holds.
   *
   * Without this the panel rendered its defaults forever: every channel showed
   * as DISABLED even when GET /settings reported `enabled: 1, url_set: 1`. That
   * is not cosmetic — PUT /settings/notifications/:type replaces the channel
   * wholesale (`$current->{$type} = { %$body }` in Settings.pm), so saving any
   * unrelated field from that stale form posted `enabled: false` and switched a
   * live alert channel off.
   *
   * Only the three `enabled` flags and `slack.channel` are hydrated, because
   * they are the only values GET returns outright. The secrets come back as
   * mere is-set booleans (`bot_token: 0|1`, `webhook_set`, `url_set`), so their
   * inputs must stay blank — `storedSecrets` above is what tells the user one
   * is already stored, and the backend restores a blank write-only field rather
   * than erasing it (_writable_values in Config.pm).
   *
   * Deliberately does NOT touch the secret inputs: this also runs on the
   * refetch after a save, and blanking them there would discard a token the
   * user had typed into a different channel.
   */
  function hydrate(settings) {
    const n = settings?.notifications;
    if (!n) return;

    notifications.telegram.enabled = !!n.telegram?.enabled;
    notifications.slack.enabled = !!n.slack?.enabled;
    notifications.slack.channel = n.slack?.channel ?? '';
    notifications.webhook.enabled = !!n.webhook?.enabled;
  }

  /**
   * Armed removals, keyed the same way: { 'telegram.bot_token': true }.
   *
   * Every key starts at `false`, never missing: each one is passed to
   * <ClearSecretToggle bind:armed>, whose prop falls back to `false`, and
   * Svelte 5 throws props_invalid_value when a bound prop with a fallback
   * receives `undefined` — which crashed the whole panel the moment a channel
   * was switched on and its toggles mounted.
   */
  let clearing = $state(Object.fromEntries(
    Object.entries(CHANNEL_SECRETS).flatMap(([type, fields]) =>
      fields.map((field) => [`${type}.${field}`, false])
    )
  ));
  let clearRequest = $state(null);

  let savingNotification = $state(null);
  let notificationMessage = $state({});
  let testingNotification = $state(null);
  let notificationTestResult = $state({});

  onMount(() => {
    fetchServerSettings();
  });

  /**
   * @param {boolean} showSpinner false for the refetch after a save: the
   *   panel is already on screen and replacing it with a spinner collapses the
   *   open channel the user is working in.
   */
  async function fetchServerSettings(showSpinner = true) {
    if (showSpinner) loadingSettings = true;
    try {
      serverSettings = await api.get('/settings');
      hydrate(serverSettings);
    } catch {
      // Ignore
    } finally {
      loadingSettings = false;
    }
  }

  /*
   * Payload without the keys the environment owns.
   *
   * The server answers 409 to any attempt to CHANGE such a key, and this form
   * never receives their current values — GET /settings only reports whether a
   * token is set. So a disabled, blank field would still be submitted as "",
   * which the server reads as a change and rejects, failing the whole save
   * including the fields the user CAN edit.
   */
  function payloadFor(type) {
    const out = {};
    for (const [key, value] of Object.entries(notifications[type])) {
      if (isEnvLocked(envKeys, `${type}.${key}`)) continue;
      out[key] = value;
    }

    // Blank every field being erased: clear_x together with a non-blank x is a
    // 400. The inputs are disabled while armed, so this only restates the rule.
    const armed = pendingClears(type);
    for (const key of armed) out[key.split('.').pop()] = '';

    return { ...out, ...clearFlags(armed) };
  }

  /** Secrets of this channel the user armed for removal. */
  function pendingClears(type) {
    return CHANNEL_SECRETS[type]
      .map((field) => `${type}.${field}`)
      .filter((key) => clearing[key]);
  }

  /** Save, but let the user confirm first when it would erase a secret. */
  function requestSaveNotification(type) {
    const armed = pendingClears(type);
    if (armed.length) {
      clearRequest = { keys: armed, run: () => saveNotification(type) };
      return;
    }
    saveNotification(type);
  }

  async function saveNotification(type) {
    savingNotification = type;
    notificationMessage[type] = null;

    const label = type.charAt(0).toUpperCase() + type.slice(1);

    try {
      const data = await api.put(`/settings/notifications/${type}`, payloadFor(type));
      const cleared = describeCleared(data.cleared);

      notificationMessage[type] = {
        success: true,
        text: cleared ? `${data.message} — ${cleared}` : data.message,
      };
      toastSuccess(cleared || `${label} settings saved`);

      // Disarm and forget the typed values, then re-read: the *_set flags the
      // removal control depends on only change server-side.
      for (const key of pendingClears(type)) clearing[key] = false;
      for (const field of CHANNEL_SECRETS[type]) notifications[type][field] = '';
      await fetchServerSettings(false);
    } catch (err) {
      // Includes the clear-specific 400s ("Not a clearable secret", "Cannot
      // clear and set the same field") and the 409 env guard — api.js lifts the
      // server's `error` into err.message, so nothing is swallowed silently.
      notificationMessage[type] = { success: false, text: err.message };
      toastError(`Failed to save ${type} settings: ${err.message}`);
    } finally {
      savingNotification = null;
    }
  }

  async function testNotification(type) {
    testingNotification = type;
    notificationTestResult[type] = null;

    try {
      notificationTestResult[type] = await api.post(`/settings/notifications/${type}/test`);
      if (notificationTestResult[type].success) {
        toastSuccess(`${type.charAt(0).toUpperCase() + type.slice(1)} test notification sent`);
      } else {
        toastError(`${type.charAt(0).toUpperCase() + type.slice(1)} test failed: ${notificationTestResult[type].error}`);
      }
    } catch (err) {
      notificationTestResult[type] = { success: false, error: err.message };
      toastError(`${type.charAt(0).toUpperCase() + type.slice(1)} test failed: ${err.message}`);
    } finally {
      testingNotification = null;
    }
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Alert Notifications</h3>
    <p>Configure notification channels for alerts</p>
  </div>

  {#if loadingSettings}
    <LoadingSpinner centered label="Loading notification settings..." />
  {:else}
  <!-- Telegram -->
  <NotificationChannelCard
    type="telegram"
    icon={telegram}
    title="Telegram"
    description="Receive alerts via Telegram bot"
    bind:enabled={notifications.telegram.enabled}
    fromEnv={serverSettings?.notifications?.telegram?.from_env}
    open={notifications.telegram.enabled || serverSettings?.notifications?.telegram?.enabled}
    testing={testingNotification === 'telegram'}
    saving={savingNotification === 'telegram'}
    testResult={notificationTestResult.telegram}
    message={notificationMessage.telegram}
    ontest={() => testNotification('telegram')}
    onsave={() => requestSaveNotification('telegram')}
  >
    <NotificationFieldRow
      label="Bot Token"
      type="password"
      bind:value={notifications.telegram.bot_token}
      placeholder="123456:ABC-DEF..."
      disabled={serverSettings?.notifications?.telegram?.from_env}
      envLocked={isEnvLocked(envKeys, 'telegram.bot_token')}
      secret="telegram.bot_token"
      stored={storedSecrets['telegram.bot_token']}
      bind:armed={clearing['telegram.bot_token']}
    />
    <NotificationFieldRow
      label="Chat ID"
      bind:value={notifications.telegram.chat_id}
      placeholder="-1001234567890"
      disabled={serverSettings?.notifications?.telegram?.from_env}
      envLocked={isEnvLocked(envKeys, 'telegram.chat_id')}
      secret="telegram.chat_id"
      stored={storedSecrets['telegram.chat_id']}
      bind:armed={clearing['telegram.chat_id']}
    />
    <NotificationFieldRow
      label="Thread ID"
      bind:value={notifications.telegram.thread_id}
      placeholder="123 (optional, for topics)"
      disabled={serverSettings?.notifications?.telegram?.from_env}
      hint="For supergroups with topics enabled"
    />
  </NotificationChannelCard>

  <!-- Slack -->
  <NotificationChannelCard
    type="slack"
    icon={slack}
    title="Slack"
    description="Post alerts to Slack channel"
    bind:enabled={notifications.slack.enabled}
    fromEnv={serverSettings?.notifications?.slack?.from_env}
    open={notifications.slack.enabled || serverSettings?.notifications?.slack?.enabled}
    testing={testingNotification === 'slack'}
    saving={savingNotification === 'slack'}
    testResult={notificationTestResult.slack}
    message={notificationMessage.slack}
    ontest={() => testNotification('slack')}
    onsave={() => requestSaveNotification('slack')}
  >
    <NotificationFieldRow
      label="Webhook URL"
      type="password"
      bind:value={notifications.slack.webhook_url}
      placeholder="https://hooks.slack.com/services/..."
      disabled={serverSettings?.notifications?.slack?.from_env}
      envLocked={isEnvLocked(envKeys, 'slack.webhook_url')}
      secret="slack.webhook_url"
      stored={storedSecrets['slack.webhook_url']}
      bind:armed={clearing['slack.webhook_url']}
    />
    <NotificationFieldRow
      label="Channel (optional)"
      bind:value={notifications.slack.channel}
      placeholder="#alerts"
      disabled={serverSettings?.notifications?.slack?.from_env}
      envLocked={isEnvLocked(envKeys, 'slack.channel')}
    />
  </NotificationChannelCard>

  <!-- Webhook -->
  <NotificationChannelCard
    type="webhook"
    icon={link}
    title="Webhook"
    description="Send to custom HTTP endpoint"
    bind:enabled={notifications.webhook.enabled}
    fromEnv={serverSettings?.notifications?.webhook?.from_env}
    open={notifications.webhook.enabled || serverSettings?.notifications?.webhook?.enabled}
    testing={testingNotification === 'webhook'}
    saving={savingNotification === 'webhook'}
    testResult={notificationTestResult.webhook}
    message={notificationMessage.webhook}
    ontest={() => testNotification('webhook')}
    onsave={() => requestSaveNotification('webhook')}
  >
    <NotificationFieldRow
      label="Webhook URL"
      bind:value={notifications.webhook.url}
      placeholder="https://your-server.com/webhook"
      disabled={serverSettings?.notifications?.webhook?.from_env}
      envLocked={isEnvLocked(envKeys, 'webhook.url')}
      secret="webhook.url"
      stored={storedSecrets['webhook.url']}
      bind:armed={clearing['webhook.url']}
    />
    <!-- Its removal toggle stays hidden until GET /settings reports webhook.auth_token_set. -->
    <NotificationFieldRow
      label="Auth Token (optional)"
      type="password"
      bind:value={notifications.webhook.auth_token}
      placeholder="Bearer token"
      disabled={serverSettings?.notifications?.webhook?.from_env}
      envLocked={isEnvLocked(envKeys, 'webhook.auth_token')}
      secret="webhook.auth_token"
      stored={storedSecrets['webhook.auth_token']}
      bind:armed={clearing['webhook.auth_token']}
    />
  </NotificationChannelCard>

  <NotificationStorageInfo />
  {/if}
</section>

<ClearSecretConfirm bind:request={clearRequest} />

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
    color: var(--text-bright);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin: 0;
  }
</style>
