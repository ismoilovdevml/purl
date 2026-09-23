<!--
  ConnectionTestFooter
  Bottom of a "test, then save" settings form (SSO, LDAP): the last test
  result banner, the save success/error line, and the Test / Save buttons.
  The page owns the requests and passes their state down.

  Usage:
  <ConnectionTestFooter
    {testResult} {testing} {saving} {saveMsg} {saveError}
    enabled={form.enabled}
    testLabel="Test Connection"
    okPrefix="Connected"
    failPrefix="Connection failed"
    ontest={handleTest}
    onsave={handleSave}
  />
-->
<script>
  import Button from './Button.svelte';
  import Icon from './Icon.svelte';
  import { check, close } from './icons.js';

  let {
    /** null | { ok: boolean, message: string } from the last test */
    testResult = null,
    /** A test request is running */
    testing = false,
    /** A save request is running */
    saving = false,
    /** Save success text ('' hides it) */
    saveMsg = '',
    /** Save error text ('' hides it) */
    saveError = '',
    /** The feature is switched on (testing a disabled config is pointless) */
    enabled = false,
    /** Test button text */
    testLabel = 'Test Connection',
    /** Banner prefix for a passed test */
    okPrefix = 'Connected',
    /** Banner prefix for a failed test */
    failPrefix = 'Connection failed',
    /** () => void */
    ontest,
    /** () => void */
    onsave,
  } = $props();
</script>

<!-- ── Test result ─────────────────────────────────────────────────────── -->
{#if testResult !== null}
  <div class="test-result" class:test-ok={testResult.ok} class:test-fail={!testResult.ok}>
    {#if testResult.ok}
      <Icon icon={check} size={14} strokeWidth={2.5} />
      {okPrefix} — {testResult.message}
    {:else}
      <Icon icon={close} size={14} strokeWidth={2.5} />
      {failPrefix}: {testResult.message}
    {/if}
  </div>
{/if}

<!-- ── Save feedback ───────────────────────────────────────────────────── -->
{#if saveMsg}
  <div class="save-msg">{saveMsg}</div>
{/if}
{#if saveError}
  <div class="error-msg">{saveError}</div>
{/if}

<!-- ── Actions row ─────────────────────────────────────────────────────── -->
<div class="actions-row">
  <Button
    variant="default"
    onclick={ontest}
    loading={testing}
    disabled={!enabled || saving}
  >
    {testLabel}
  </Button>
  <Button
    variant="primary"
    onclick={onsave}
    loading={saving}
    disabled={testing}
  >
    Save Settings
  </Button>
</div>

<style>
  /* ── Test result banner ──────────────────────────────────────────────────── */
  .test-result {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    border-radius: 6px;
    font-size: 0.8125rem;
    font-weight: 500;
  }

  .test-ok {
    background: rgba(35, 134, 54, 0.12);
    border: 1px solid rgba(35, 134, 54, 0.4);
    color: var(--color-success);
  }

  .test-fail {
    background: rgba(248, 81, 73, 0.10);
    border: 1px solid var(--color-error);
    color: var(--color-error);
  }

  /* ── Save messages ───────────────────────────────────────────────────────── */
  .save-msg {
    padding: 10px 14px;
    background: rgba(35, 134, 54, 0.10);
    border: 1px solid rgba(35, 134, 54, 0.35);
    border-radius: 6px;
    color: var(--color-success);
    font-size: 0.8125rem;
  }

  .error-msg {
    padding: 10px 14px;
    background: rgba(248, 81, 73, 0.10);
    border: 1px solid var(--color-error);
    border-radius: 6px;
    color: var(--color-error);
    font-size: 0.8125rem;
  }

  /* ── Actions row ─────────────────────────────────────────────────────────── */
  .actions-row {
    display: flex;
    gap: 10px;
    align-items: center;
    padding-top: 4px;
  }
</style>
