<!--
  NotificationChannelCard
  One alert channel (Telegram, Slack, Webhook): the header with its enable
  switch, and — while the channel is on — its fields, Test / Save buttons and
  the last test / save outcome. NotificationSettings owns every value and
  request; the channel's fields come in as the `children` snippet.
-->
<script>
  import Card from '../../ui/Card.svelte';
  import Badge from '../../ui/Badge.svelte';
  import Button from '../../ui/Button.svelte';
  import Icon from '../../ui/Icon.svelte';

  let {
    /** Channel type, also the icon's colour class: 'telegram' | 'slack' | 'webhook' */
    type,
    /** Header icon (from ui/icons.js) */
    icon,
    /** Header title */
    title,
    /** Header subtitle */
    description,
    /** Bound: the channel's enable switch */
    enabled = $bindable(),
    /** The server says the environment owns this channel: everything is locked */
    fromEnv = false,
    /** Show the form (switched on here, or enabled on the server) */
    open = false,
    /** A test request for this channel is running */
    testing = false,
    /** A save request for this channel is running */
    saving = false,
    /** Last test answer: { success, message?, error? } or null */
    testResult = null,
    /** Last save outcome: { success, text } or null */
    message = null,
    /** () => void */
    ontest,
    /** () => void */
    onsave,
    /** The channel's field rows (snippet) */
    children,
  } = $props();
</script>

<Card padding="none" class="notification-card">
  <div class="notification-header">
    <div class="notification-icon {type}">
      <Icon {icon} size={24} />
    </div>
    <div class="notification-info">
      <h4>{title}</h4>
      <p>{description}</p>
    </div>
    <div class="notification-toggle">
      <label class="toggle">
        <input type="checkbox" bind:checked={enabled} disabled={fromEnv} />
        <span class="toggle-slider"></span>
      </label>
    </div>
    {#if fromEnv}
      <Badge variant="warning" size="sm">From Environment</Badge>
    {/if}
  </div>

  {#if open}
  <div class="notification-form">
    {@render children?.()}
    <div class="form-actions">
      <Button variant="default" onclick={ontest} loading={testing}>
        {testing ? 'Testing...' : 'Test'}
      </Button>
      <Button variant="success" onclick={onsave} loading={saving} disabled={fromEnv}>
        {saving ? 'Saving...' : 'Save'}
      </Button>
    </div>
    {#if testResult}
      <div class="result-box" class:success={testResult.success}>
        {testResult.success ? testResult.message : testResult.error}
      </div>
    {/if}
    {#if message}
      <div class="result-box" class:success={message.success}>
        {message.text}
      </div>
    {/if}
  </div>
  {/if}
</Card>

<style>
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
</style>
