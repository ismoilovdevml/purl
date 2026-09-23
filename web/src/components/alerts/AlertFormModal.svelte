<!--
  AlertFormModal
  The Create/Edit alert modal: name, query, threshold, window and the
  notification channel (with its target field, or a note for Telegram, which
  is configured server-side). AlertsPanel owns `form` and performs the save.
-->
<script>
  import Button from '../ui/Button.svelte';
  import Input from '../ui/Input.svelte';
  import Select from '../ui/Select.svelte';
  import Modal from '../ui/Modal.svelte';

  let {
    /** Modal visibility */
    open = $bindable(),
    /** { name, query, threshold, window_minutes, notify_type, notify_target } */
    form = $bindable(),
    /** Editing an existing alert (vs. creating one) — only changes the title */
    editing = false,
    /** Selectable notify_type options: [{ value, label }] */
    notifyOptions,
    /** () => void */
    onsave,
  } = $props();
</script>

<Modal bind:open title={editing ? 'Edit Alert' : 'Create Alert'} size="md">
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

  {#snippet footer()}
    <Button variant="default" onclick={() => open = false}>Cancel</Button>
    <Button variant="success" onclick={onsave}>Save</Button>
  {/snippet}
</Modal>

<style>
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
