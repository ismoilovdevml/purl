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

  const API_BASE = '/api';

  let serverSettings = null;

  let notifications = {
    telegram: { enabled: false, bot_token: '', chat_id: '' },
    slack: { enabled: false, webhook_url: '', channel: '' },
    webhook: { enabled: false, url: '', auth_token: '' }
  };

  let savingNotification = null;
  let notificationMessage = {};
  let testingNotification = null;
  let notificationTestResult = {};

  onMount(() => {
    fetchServerSettings();
  });

  function getHeaders() {
    return { 'Content-Type': 'application/json' };
  }

  async function fetchServerSettings() {
    try {
      const res = await fetch(`${API_BASE}/settings`, { headers: getHeaders() });
      if (res.ok) {
        serverSettings = await res.json();
      }
    } catch {
      // Ignore
    }
  }

  async function saveNotification(type) {
    savingNotification = type;
    notificationMessage[type] = null;

    try {
      const res = await fetch(`${API_BASE}/settings/notifications/${type}`, {
        method: 'PUT',
        headers: getHeaders(),
        body: JSON.stringify(notifications[type])
      });

      const data = await res.json();
      if (res.ok) {
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
      const res = await fetch(`${API_BASE}/settings/notifications/${type}/test`, {
        method: 'POST',
        headers: getHeaders()
      });

      notificationTestResult[type] = await res.json();
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
  <Card padding="none" class="notification-card">
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
        <Badge variant="warning" size="sm">From Environment</Badge>
      {/if}
    </div>

    <div class="notification-form">
      <div class="form-row">
        <span class="form-label">Bot Token</span>
        <Input
          type="password"
          bind:value={notifications.telegram.bot_token}
          placeholder="123456:ABC-DEF..."
          disabled={serverSettings?.notifications?.telegram?.from_env}
          fullWidth
        />
      </div>
      <div class="form-row">
        <span class="form-label">Chat ID</span>
        <Input
          bind:value={notifications.telegram.chat_id}
          placeholder="-1001234567890"
          disabled={serverSettings?.notifications?.telegram?.from_env}
          fullWidth
        />
      </div>
      <div class="form-actions">
        <Button variant="default" on:click={() => testNotification('telegram')} loading={testingNotification === 'telegram'}>
          {testingNotification === 'telegram' ? 'Testing...' : 'Test'}
        </Button>
        <Button variant="success" on:click={() => saveNotification('telegram')} loading={savingNotification === 'telegram'} disabled={serverSettings?.notifications?.telegram?.from_env}>
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
  </Card>

  <!-- Slack -->
  <Card padding="none" class="notification-card">
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
        <Badge variant="warning" size="sm">From Environment</Badge>
      {/if}
    </div>

    <div class="notification-form">
      <div class="form-row">
        <span class="form-label">Webhook URL</span>
        <Input
          type="password"
          bind:value={notifications.slack.webhook_url}
          placeholder="https://hooks.slack.com/services/..."
          disabled={serverSettings?.notifications?.slack?.from_env}
          fullWidth
        />
      </div>
      <div class="form-row">
        <span class="form-label">Channel (optional)</span>
        <Input
          bind:value={notifications.slack.channel}
          placeholder="#alerts"
          disabled={serverSettings?.notifications?.slack?.from_env}
          fullWidth
        />
      </div>
      <div class="form-actions">
        <Button variant="default" on:click={() => testNotification('slack')} loading={testingNotification === 'slack'}>
          {testingNotification === 'slack' ? 'Testing...' : 'Test'}
        </Button>
        <Button variant="success" on:click={() => saveNotification('slack')} loading={savingNotification === 'slack'} disabled={serverSettings?.notifications?.slack?.from_env}>
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
  </Card>

  <!-- Webhook -->
  <Card padding="none" class="notification-card">
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
        <Badge variant="warning" size="sm">From Environment</Badge>
      {/if}
    </div>

    <div class="notification-form">
      <div class="form-row">
        <span class="form-label">Webhook URL</span>
        <Input
          bind:value={notifications.webhook.url}
          placeholder="https://your-server.com/webhook"
          disabled={serverSettings?.notifications?.webhook?.from_env}
          fullWidth
        />
      </div>
      <div class="form-row">
        <span class="form-label">Auth Token (optional)</span>
        <Input
          type="password"
          bind:value={notifications.webhook.auth_token}
          placeholder="Bearer token"
          disabled={serverSettings?.notifications?.webhook?.from_env}
          fullWidth
        />
      </div>
      <div class="form-actions">
        <Button variant="default" on:click={() => testNotification('webhook')} loading={testingNotification === 'webhook'}>
          {testingNotification === 'webhook' ? 'Testing...' : 'Test'}
        </Button>
        <Button variant="success" on:click={() => saveNotification('webhook')} loading={savingNotification === 'webhook'} disabled={serverSettings?.notifications?.webhook?.from_env}>
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
  </Card>

  <Card padding="md" class="auth-info-card">
    <h4>Settings Storage</h4>
    <p>Notification settings are saved to <code>/app/config/settings.json</code> on the server.</p>
    <p>Environment variables take precedence over UI settings and cannot be modified here.</p>
  </Card>
</section>

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
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
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
    border-bottom: 1px solid var(--border-color, #21262d);
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
    color: var(--color-primary, #58a6ff);
  }

  .notification-info {
    flex: 1;
  }

  .notification-info h4 {
    margin: 0;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
  }

  .notification-info p {
    margin: 2px 0 0;
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
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
    color: var(--text-secondary, #8b949e);
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
    color: var(--color-error, #f85149);
    background: rgba(248, 81, 73, 0.1);
    border-radius: 6px;
  }

  .result-box.success {
    color: var(--color-success, #3fb950);
    background: rgba(63, 185, 80, 0.1);
  }

  :global(.auth-info-card) {
    margin-top: 24px;
  }

  :global(.auth-info-card) h4 {
    margin: 0 0 8px;
    font-size: 0.875rem;
    color: var(--text-primary, #f0f6fc);
  }

  :global(.auth-info-card) p {
    margin: 8px 0;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
  }

  :global(.auth-info-card) code {
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 4px;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
  }
</style>
