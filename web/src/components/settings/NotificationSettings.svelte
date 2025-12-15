<script>
  import {
    saveNotification as apiSaveNotification,
    testNotification as apiTestNotification
  } from '../../lib/api.js';

  export let serverSettings = null;

  let notifications = {
    telegram: { enabled: false, bot_token: '', chat_id: '' },
    slack: { enabled: false, webhook_url: '', channel: '' },
    webhook: { enabled: false, url: '', auth_token: '' }
  };
  let savingNotification = null;
  let notificationMessage = {};
  let testingNotification = null;
  let notificationTestResult = {};

  async function saveNotification(type) {
    savingNotification = type;
    notificationMessage[type] = null;
    try {
      const data = await apiSaveNotification(type, notifications[type]);
      if (data.message) {
        notificationMessage[type] = { success: true, text: data.message };
      } else {
        notificationMessage[type] = { success: false, text: data.error };
      }
    } catch (err) {
      notificationMessage[type] = { success: false, text: err.message };
    } finally {
      savingNotification = null;
    }
  }

  async function testNotification(type) {
    testingNotification = type;
    notificationTestResult[type] = null;
    try {
      notificationTestResult[type] = await apiTestNotification(type);
    } catch (err) {
      notificationTestResult[type] = { success: false, error: err.message };
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

  <!-- Telegram -->
  <div class="notification-card">
    <div class="notification-header">
      <div class="notification-icon telegram">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8c-.15 1.58-.8 5.42-1.13 7.19-.14.75-.42 1-.68 1.03-.58.05-1.02-.38-1.58-.75-.88-.58-1.38-.94-2.23-1.5-.99-.65-.35-1.01.22-1.59.15-.15 2.71-2.48 2.76-2.69a.2.2 0 00-.05-.18c-.06-.05-.14-.03-.21-.02-.09.02-1.49.95-4.22 2.79-.4.27-.76.41-1.08.4-.36-.01-1.04-.2-1.55-.37-.63-.2-1.12-.31-1.08-.66.02-.18.27-.36.74-.55 2.92-1.27 4.86-2.11 5.83-2.51 2.78-1.16 3.35-1.36 3.73-1.36.08 0 .27.02.39.12.1.08.13.19.14.27-.01.06.01.24 0 .38z"/>
        </svg>
      </div>
      <div class="notification-info">
        <h4>Telegram</h4>
        <p>Receive alerts via Telegram bot</p>
      </div>
      {#if serverSettings?.notifications?.telegram?.from_env}
        <span class="env-badge">From Environment</span>
      {/if}
    </div>

    <div class="notification-form">
      <div class="form-field">
        <label for="telegram-token">Bot Token</label>
        <input
          id="telegram-token"
          type="password"
          bind:value={notifications.telegram.bot_token}
          placeholder="123456:ABC-DEF..."
          disabled={serverSettings?.notifications?.telegram?.from_env}
        />
      </div>
      <div class="form-field">
        <label for="telegram-chat">Chat ID</label>
        <input
          id="telegram-chat"
          type="text"
          bind:value={notifications.telegram.chat_id}
          placeholder="-1001234567890"
          disabled={serverSettings?.notifications?.telegram?.from_env}
        />
      </div>
      <div class="form-actions">
        <button class="test-btn" on:click={() => testNotification('telegram')} disabled={testingNotification === 'telegram'}>
          {testingNotification === 'telegram' ? 'Testing...' : 'Test'}
        </button>
        <button class="save-btn" on:click={() => saveNotification('telegram')} disabled={savingNotification === 'telegram' || serverSettings?.notifications?.telegram?.from_env}>
          {savingNotification === 'telegram' ? 'Saving...' : 'Save'}
        </button>
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
  </div>

  <!-- Slack -->
  <div class="notification-card">
    <div class="notification-header">
      <div class="notification-icon slack">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
          <path d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z"/>
        </svg>
      </div>
      <div class="notification-info">
        <h4>Slack</h4>
        <p>Post alerts to Slack channel</p>
      </div>
      {#if serverSettings?.notifications?.slack?.from_env}
        <span class="env-badge">From Environment</span>
      {/if}
    </div>

    <div class="notification-form">
      <div class="form-field">
        <label for="slack-webhook">Webhook URL</label>
        <input
          id="slack-webhook"
          type="password"
          bind:value={notifications.slack.webhook_url}
          placeholder="https://hooks.slack.com/services/..."
          disabled={serverSettings?.notifications?.slack?.from_env}
        />
      </div>
      <div class="form-field">
        <label for="slack-channel">Channel (optional)</label>
        <input
          id="slack-channel"
          type="text"
          bind:value={notifications.slack.channel}
          placeholder="#alerts"
          disabled={serverSettings?.notifications?.slack?.from_env}
        />
      </div>
      <div class="form-actions">
        <button class="test-btn" on:click={() => testNotification('slack')} disabled={testingNotification === 'slack'}>
          {testingNotification === 'slack' ? 'Testing...' : 'Test'}
        </button>
        <button class="save-btn" on:click={() => saveNotification('slack')} disabled={savingNotification === 'slack' || serverSettings?.notifications?.slack?.from_env}>
          {savingNotification === 'slack' ? 'Saving...' : 'Save'}
        </button>
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
  </div>

  <!-- Webhook -->
  <div class="notification-card">
    <div class="notification-header">
      <div class="notification-icon webhook">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>
          <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>
        </svg>
      </div>
      <div class="notification-info">
        <h4>Webhook</h4>
        <p>Send to custom HTTP endpoint</p>
      </div>
      {#if serverSettings?.notifications?.webhook?.from_env}
        <span class="env-badge">From Environment</span>
      {/if}
    </div>

    <div class="notification-form">
      <div class="form-field">
        <label for="webhook-url">Webhook URL</label>
        <input
          id="webhook-url"
          type="text"
          bind:value={notifications.webhook.url}
          placeholder="https://your-server.com/webhook"
          disabled={serverSettings?.notifications?.webhook?.from_env}
        />
      </div>
      <div class="form-field">
        <label for="webhook-token">Auth Token (optional)</label>
        <input
          id="webhook-token"
          type="password"
          bind:value={notifications.webhook.auth_token}
          placeholder="Bearer token"
          disabled={serverSettings?.notifications?.webhook?.from_env}
        />
      </div>
      <div class="form-actions">
        <button class="test-btn" on:click={() => testNotification('webhook')} disabled={testingNotification === 'webhook'}>
          {testingNotification === 'webhook' ? 'Testing...' : 'Test'}
        </button>
        <button class="save-btn" on:click={() => saveNotification('webhook')} disabled={savingNotification === 'webhook' || serverSettings?.notifications?.webhook?.from_env}>
          {savingNotification === 'webhook' ? 'Saving...' : 'Save'}
        </button>
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
  </div>

  <div class="auth-info">
    <h4>Settings Storage</h4>
    <p>Notification settings are saved to <code>/app/config/settings.json</code> on the server.</p>
    <p>Environment variables take precedence over UI settings and cannot be modified here.</p>
  </div>
</section>

<style>
  .settings-section { max-width: 800px; }
  .section-header { margin-bottom: 24px; }
  .section-header h3 { font-size: 1.25rem; font-weight: 600; color: #f0f6fc; margin: 0 0 4px; }
  .section-header p { font-size: 0.875rem; color: #8b949e; margin: 0; }

  .env-badge {
    font-size: 0.6875rem;
    font-weight: 500;
    color: #d29922;
    background: #d2992220;
    padding: 2px 8px;
    border-radius: 10px;
  }

  .notification-card {
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 8px;
    margin-bottom: 16px;
    overflow: hidden;
  }

  .notification-header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 16px;
    border-bottom: 1px solid #21262d;
  }

  .notification-icon {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .notification-icon.telegram { background: #0088cc20; color: #0088cc; }
  .notification-icon.slack { background: #4a154b20; color: #e01e5a; }
  .notification-icon.webhook { background: #58a6ff20; color: #58a6ff; }

  .notification-info { flex: 1; }
  .notification-info h4 { margin: 0; font-size: 0.9375rem; font-weight: 600; color: #f0f6fc; }
  .notification-info p { margin: 2px 0 0; font-size: 0.75rem; color: #8b949e; }

  .notification-form { padding: 16px; display: flex; flex-direction: column; gap: 12px; }

  .notification-form .form-field {
    display: flex;
    flex-direction: row;
    align-items: center;
    gap: 12px;
  }

  .notification-form .form-field label { width: 120px; flex-shrink: 0; font-size: 0.8125rem; color: #8b949e; }
  .notification-form .form-field input { flex: 1; padding: 8px 12px; background: #0d1117; border: 1px solid #30363d; border-radius: 6px; color: #c9d1d9; font-size: 0.875rem; }
  .notification-form .form-field input:focus { outline: none; border-color: #58a6ff; }
  .notification-form .form-field input:disabled { opacity: 0.6; cursor: not-allowed; }

  .form-actions { display: flex; gap: 8px; justify-content: flex-end; }

  .result-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    font-size: 0.8125rem;
    color: #f85149;
    background: #f8514915;
    border-radius: 6px;
  }

  .result-box.success { color: #3fb950; background: #3fb95015; }

  .save-btn, .test-btn {
    padding: 8px 16px;
    border-radius: 6px;
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .save-btn { background: #238636; border: 1px solid #238636; color: #fff; }
  .save-btn:hover:not(:disabled) { background: #2ea043; }
  .save-btn:disabled { opacity: 0.5; cursor: not-allowed; }

  .test-btn { background: transparent; border: 1px solid #30363d; color: #c9d1d9; }
  .test-btn:hover:not(:disabled) { background: #21262d; border-color: #8b949e; }
  .test-btn:disabled { opacity: 0.5; cursor: not-allowed; }

  .auth-info {
    margin-top: 24px;
    padding: 16px;
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 8px;
  }

  .auth-info h4 { margin: 0 0 8px; font-size: 0.875rem; color: #f0f6fc; }
  .auth-info p { margin: 8px 0; font-size: 0.8125rem; color: #8b949e; }
  .auth-info code { background: #21262d; padding: 2px 6px; border-radius: 4px; font-size: 0.75rem; }
</style>
