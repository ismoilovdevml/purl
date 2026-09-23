<!--
  NotificationSettings Component
  Telegram, Slack, and Webhook notification configuration

  Usage:
  <NotificationSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Input from '../ui/Input.svelte';
  import Button from '../ui/Button.svelte';
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import EnvBadge from '../ui/EnvBadge.svelte';
  import ClearSecretToggle from '../ui/ClearSecretToggle.svelte';
  import ClearSecretConfirm from '../ui/ClearSecretConfirm.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import { isEnvLocked } from '../../utils/envLock.js';
  import { clearFlags, describeCleared } from '../../utils/clearSecret.js';
  import Icon from '../ui/Icon.svelte';
  import { telegram, slack, link } from '../ui/icons.js';

  let serverSettings = null;
  let loadingSettings = true;

  let notifications = {
    telegram: { enabled: false, bot_token: '', chat_id: '', thread_id: '' },
    slack: { enabled: false, webhook_url: '', channel: '' },
    webhook: { enabled: false, url: '', auth_token: '' }
  };

  /*
   * Per-key truth, keyed by the dotted name inside the notifications section
   * ('telegram.chat_id', 'slack.channel', 'webhook.auth_token', ...).
   *
   * The per-channel `from_env` flags below it only track each channel's
   * bot_token/webhook_url, so a chat_id or channel pinned by its OWN variable
   * rendered editable and 409'd on save. Both are consulted; neither replaces
   * the other.
   */
  $: envKeys = serverSettings?.notifications?.from_env_keys;

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

  $: storedSecrets = storedSecretsFrom(serverSettings);

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
  let clearing = Object.fromEntries(
    Object.entries(CHANNEL_SECRETS).flatMap(([type, fields]) =>
      fields.map((field) => [`${type}.${field}`, false])
    )
  );
  let clearRequest = null;

  let savingNotification = null;
  let notificationMessage = {};
  let testingNotification = null;
  let notificationTestResult = {};

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
  <Card padding="none" class="notification-card">
    <div class="notification-header">
      <div class="notification-icon telegram">
        <Icon icon={telegram} size={24} />
      </div>
      <div class="notification-info">
        <h4>Telegram</h4>
        <p>Receive alerts via Telegram bot</p>
      </div>
      <div class="notification-toggle">
        <label class="toggle">
          <input type="checkbox" bind:checked={notifications.telegram.enabled} disabled={serverSettings?.notifications?.telegram?.from_env} />
          <span class="toggle-slider"></span>
        </label>
      </div>
      {#if serverSettings?.notifications?.telegram?.from_env}
        <Badge variant="warning" size="sm">From Environment</Badge>
      {/if}
    </div>

    {#if notifications.telegram.enabled || serverSettings?.notifications?.telegram?.enabled}
    <div class="notification-form">
      <div class="form-row">
        <span class="form-label">
          Bot Token
          <EnvBadge locked={isEnvLocked(envKeys, 'telegram.bot_token')} />
        </span>
        <Input
          type="password"
          bind:value={notifications.telegram.bot_token}
          placeholder={clearing['telegram.bot_token'] ? 'Will be removed on save' : '123456:ABC-DEF...'}
          disabled={serverSettings?.notifications?.telegram?.from_env || isEnvLocked(envKeys, 'telegram.bot_token') || clearing['telegram.bot_token']}
          fullWidth
        />
        <div class="clear-slot">
          <ClearSecretToggle
            secret="telegram.bot_token"
            stored={storedSecrets['telegram.bot_token']}
            envLocked={isEnvLocked(envKeys, 'telegram.bot_token')}
            disabled={serverSettings?.notifications?.telegram?.from_env}
            bind:armed={clearing['telegram.bot_token']}
          />
        </div>
      </div>
      <div class="form-row">
        <span class="form-label">
          Chat ID
          <EnvBadge locked={isEnvLocked(envKeys, 'telegram.chat_id')} />
        </span>
        <Input
          bind:value={notifications.telegram.chat_id}
          placeholder={clearing['telegram.chat_id'] ? 'Will be removed on save' : '-1001234567890'}
          disabled={serverSettings?.notifications?.telegram?.from_env || isEnvLocked(envKeys, 'telegram.chat_id') || clearing['telegram.chat_id']}
          fullWidth
        />
        <div class="clear-slot">
          <ClearSecretToggle
            secret="telegram.chat_id"
            stored={storedSecrets['telegram.chat_id']}
            envLocked={isEnvLocked(envKeys, 'telegram.chat_id')}
            disabled={serverSettings?.notifications?.telegram?.from_env}
            bind:armed={clearing['telegram.chat_id']}
          />
        </div>
      </div>
      <div class="form-row">
        <span class="form-label">Thread ID</span>
        <Input
          bind:value={notifications.telegram.thread_id}
          placeholder="123 (optional, for topics)"
          disabled={serverSettings?.notifications?.telegram?.from_env}
          fullWidth
        />
        <span class="form-hint">For supergroups with topics enabled</span>
      </div>
      <div class="form-actions">
        <Button variant="default" on:click={() => testNotification('telegram')} loading={testingNotification === 'telegram'}>
          {testingNotification === 'telegram' ? 'Testing...' : 'Test'}
        </Button>
        <Button variant="success" on:click={() => requestSaveNotification('telegram')} loading={savingNotification === 'telegram'} disabled={serverSettings?.notifications?.telegram?.from_env}>
          {savingNotification === 'telegram' ? 'Saving...' : 'Save'}
        </Button>
      </div>
      {#if notificationTestResult.telegram}
        <div class="result-box" class:success={notificationTestResult.telegram.success}>
          {notificationTestResult.telegram.success ? notificationTestResult.telegram.message : notificationTestResult.telegram.error}
        </div>
      {/if}
      {#if notificationMessage.telegram}
        <div class="result-box" class:success={notificationMessage.telegram.success}>
          {notificationMessage.telegram.text}
        </div>
      {/if}
    </div>
    {/if}
  </Card>

  <!-- Slack -->
  <Card padding="none" class="notification-card">
    <div class="notification-header">
      <div class="notification-icon slack">
        <Icon icon={slack} size={24} />
      </div>
      <div class="notification-info">
        <h4>Slack</h4>
        <p>Post alerts to Slack channel</p>
      </div>
      <div class="notification-toggle">
        <label class="toggle">
          <input type="checkbox" bind:checked={notifications.slack.enabled} disabled={serverSettings?.notifications?.slack?.from_env} />
          <span class="toggle-slider"></span>
        </label>
      </div>
      {#if serverSettings?.notifications?.slack?.from_env}
        <Badge variant="warning" size="sm">From Environment</Badge>
      {/if}
    </div>

    {#if notifications.slack.enabled || serverSettings?.notifications?.slack?.enabled}
    <div class="notification-form">
      <div class="form-row">
        <span class="form-label">
          Webhook URL
          <EnvBadge locked={isEnvLocked(envKeys, 'slack.webhook_url')} />
        </span>
        <Input
          type="password"
          bind:value={notifications.slack.webhook_url}
          placeholder={clearing['slack.webhook_url'] ? 'Will be removed on save' : 'https://hooks.slack.com/services/...'}
          disabled={serverSettings?.notifications?.slack?.from_env || isEnvLocked(envKeys, 'slack.webhook_url') || clearing['slack.webhook_url']}
          fullWidth
        />
        <div class="clear-slot">
          <ClearSecretToggle
            secret="slack.webhook_url"
            stored={storedSecrets['slack.webhook_url']}
            envLocked={isEnvLocked(envKeys, 'slack.webhook_url')}
            disabled={serverSettings?.notifications?.slack?.from_env}
            bind:armed={clearing['slack.webhook_url']}
          />
        </div>
      </div>
      <div class="form-row">
        <span class="form-label">
          Channel (optional)
          <EnvBadge locked={isEnvLocked(envKeys, 'slack.channel')} />
        </span>
        <Input
          bind:value={notifications.slack.channel}
          placeholder="#alerts"
          disabled={serverSettings?.notifications?.slack?.from_env || isEnvLocked(envKeys, 'slack.channel')}
          fullWidth
        />
      </div>
      <div class="form-actions">
        <Button variant="default" on:click={() => testNotification('slack')} loading={testingNotification === 'slack'}>
          {testingNotification === 'slack' ? 'Testing...' : 'Test'}
        </Button>
        <Button variant="success" on:click={() => requestSaveNotification('slack')} loading={savingNotification === 'slack'} disabled={serverSettings?.notifications?.slack?.from_env}>
          {savingNotification === 'slack' ? 'Saving...' : 'Save'}
        </Button>
      </div>
      {#if notificationTestResult.slack}
        <div class="result-box" class:success={notificationTestResult.slack.success}>
          {notificationTestResult.slack.success ? notificationTestResult.slack.message : notificationTestResult.slack.error}
        </div>
      {/if}
      {#if notificationMessage.slack}
        <div class="result-box" class:success={notificationMessage.slack.success}>
          {notificationMessage.slack.text}
        </div>
      {/if}
    </div>
    {/if}
  </Card>

  <!-- Webhook -->
  <Card padding="none" class="notification-card">
    <div class="notification-header">
      <div class="notification-icon webhook">
        <Icon icon={link} size={24} />
      </div>
      <div class="notification-info">
        <h4>Webhook</h4>
        <p>Send to custom HTTP endpoint</p>
      </div>
      <div class="notification-toggle">
        <label class="toggle">
          <input type="checkbox" bind:checked={notifications.webhook.enabled} disabled={serverSettings?.notifications?.webhook?.from_env} />
          <span class="toggle-slider"></span>
        </label>
      </div>
      {#if serverSettings?.notifications?.webhook?.from_env}
        <Badge variant="warning" size="sm">From Environment</Badge>
      {/if}
    </div>

    {#if notifications.webhook.enabled || serverSettings?.notifications?.webhook?.enabled}
    <div class="notification-form">
      <div class="form-row">
        <span class="form-label">
          Webhook URL
          <EnvBadge locked={isEnvLocked(envKeys, 'webhook.url')} />
        </span>
        <Input
          bind:value={notifications.webhook.url}
          placeholder={clearing['webhook.url'] ? 'Will be removed on save' : 'https://your-server.com/webhook'}
          disabled={serverSettings?.notifications?.webhook?.from_env || isEnvLocked(envKeys, 'webhook.url') || clearing['webhook.url']}
          fullWidth
        />
        <div class="clear-slot">
          <ClearSecretToggle
            secret="webhook.url"
            stored={storedSecrets['webhook.url']}
            envLocked={isEnvLocked(envKeys, 'webhook.url')}
            disabled={serverSettings?.notifications?.webhook?.from_env}
            bind:armed={clearing['webhook.url']}
          />
        </div>
      </div>
      <div class="form-row">
        <span class="form-label">
          Auth Token (optional)
          <EnvBadge locked={isEnvLocked(envKeys, 'webhook.auth_token')} />
        </span>
        <Input
          type="password"
          bind:value={notifications.webhook.auth_token}
          placeholder={clearing['webhook.auth_token'] ? 'Will be removed on save' : 'Bearer token'}
          disabled={serverSettings?.notifications?.webhook?.from_env || isEnvLocked(envKeys, 'webhook.auth_token') || clearing['webhook.auth_token']}
          fullWidth
        />
        <div class="clear-slot">
          <!-- Hidden until GET /settings reports webhook.auth_token_set. -->
          <ClearSecretToggle
            secret="webhook.auth_token"
            stored={storedSecrets['webhook.auth_token']}
            envLocked={isEnvLocked(envKeys, 'webhook.auth_token')}
            disabled={serverSettings?.notifications?.webhook?.from_env}
            bind:armed={clearing['webhook.auth_token']}
          />
        </div>
      </div>
      <div class="form-actions">
        <Button variant="default" on:click={() => testNotification('webhook')} loading={testingNotification === 'webhook'}>
          {testingNotification === 'webhook' ? 'Testing...' : 'Test'}
        </Button>
        <Button variant="success" on:click={() => requestSaveNotification('webhook')} loading={savingNotification === 'webhook'} disabled={serverSettings?.notifications?.webhook?.from_env}>
          {savingNotification === 'webhook' ? 'Saving...' : 'Save'}
        </Button>
      </div>
      {#if notificationTestResult.webhook}
        <div class="result-box" class:success={notificationTestResult.webhook.success}>
          {notificationTestResult.webhook.success ? notificationTestResult.webhook.message : notificationTestResult.webhook.error}
        </div>
      {/if}
      {#if notificationMessage.webhook}
        <div class="result-box" class:success={notificationMessage.webhook.success}>
          {notificationMessage.webhook.text}
        </div>
      {/if}
    </div>
    {/if}
  </Card>

  <Card padding="md" class="auth-info-card">
    <h4>Settings Storage</h4>
    <p>Notification settings are saved to <code>/app/config/settings.json</code> on the server.</p>
    <p>Environment variables take precedence over UI settings and cannot be modified here.</p>
  </Card>
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

  :global(.notification-card) {
    margin-bottom: 16px;
  }

  .notification-header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 16px;
    border-bottom: 1px solid var(--border-muted);
  }

  .notification-icon {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .notification-icon.telegram {
    background: rgba(0, 136, 204, 0.15);
    color: #0088cc;
  }

  .notification-icon.slack {
    background: rgba(74, 21, 75, 0.15);
    color: #e01e5a;
  }

  .notification-icon.webhook {
    background: rgba(88, 166, 255, 0.15);
    color: var(--color-primary);
  }

  .notification-info {
    flex: 1;
  }

  .notification-info h4 {
    margin: 0;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-bright);
  }

  .notification-info p {
    margin: 2px 0 0;
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .notification-form {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .form-row {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .form-label {
    width: 140px;
    flex-shrink: 0;
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  .form-actions {
    display: flex;
    gap: 8px;
    justify-content: flex-end;
  }

  .result-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    font-size: 0.8125rem;
    color: var(--color-error);
    background: rgba(248, 81, 73, 0.1);
    border-radius: 6px;
  }

  .result-box.success {
    color: var(--color-success);
    background: rgba(63, 185, 80, 0.1);
  }

  .notification-toggle {
    margin-left: auto;
  }

  .toggle {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
  }

  .toggle input {
    opacity: 0;
    width: 0;
    height: 0;
  }

  .toggle-slider {
    position: absolute;
    cursor: pointer;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background-color: var(--bg-tertiary);
    border-radius: 24px;
    transition: 0.2s;
  }

  .toggle-slider:before {
    position: absolute;
    content: "";
    height: 18px;
    width: 18px;
    left: 3px;
    bottom: 3px;
    background-color: #8b949e;
    border-radius: 50%;
    transition: 0.2s;
  }

  .toggle input:checked + .toggle-slider {
    background-color: var(--color-success-solid);
  }

  .toggle input:checked + .toggle-slider:before {
    transform: translateX(20px);
    background-color: #fff;
  }

  .toggle input:disabled + .toggle-slider {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .form-hint {
    font-size: 0.6875rem;
    color: var(--text-muted);
    margin-left: 8px;
  }

  /* Own line under the input it belongs to (.form-row wraps), aligned with the
     input rather than with the 140px label column. */
  .clear-slot {
    flex-basis: 100%;
    padding-left: 152px;
  }

  /* No stored secret => the toggle renders nothing => no blank row. */
  .clear-slot:empty {
    display: none;
  }

  .form-row {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }

  :global(.auth-info-card) {
    margin-top: 24px;
  }

  :global(.auth-info-card) h4 {
    margin: 0 0 8px;
    font-size: 0.875rem;
    color: var(--text-bright);
  }

  :global(.auth-info-card) p {
    margin: 8px 0;
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  :global(.auth-info-card) code {
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 4px;
    font-family: var(--font-mono);
  }
</style>
