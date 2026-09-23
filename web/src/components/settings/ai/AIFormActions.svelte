<!--
  AIFormActions
  Footer of the AI settings form: the last connection-test result (if any)
  and the Test Connection / Save buttons. AISettings owns the requests.
-->
<script>
  import Icon from '../../ui/Icon.svelte';
  import { alertCircle, check } from '../../ui/icons.js';

  let {
    /** { status: 'ok'|'error', message, model? } from the last test, or null */
    testResult = null,
    /** A connection test is running */
    testing = false,
    /** Settings are loading or saving */
    loading = false,
    /** () => void */
    ontest,
    /** () => void */
    onsave,
  } = $props();
</script>

{#if testResult}
  <div class="test-result" class:success={testResult.status === 'ok'} class:error={testResult.status === 'error'}>
    <Icon icon={testResult.status === 'ok' ? check : alertCircle} size={14} strokeWidth={2.5} />
    {testResult.message}
    {#if testResult.model}<span class="model-name"> ({testResult.model})</span>{/if}
  </div>
{/if}

<div class="actions">
  <button class="btn-test" onclick={ontest} disabled={testing || loading}>
    {testing ? 'Testing…' : 'Test Connection'}
  </button>
  <button class="btn-save" onclick={onsave} disabled={loading}>
    {loading ? 'Saving…' : 'Save'}
  </button>
</div>

<style>
  .test-result {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    padding: 8px 12px;
    border-radius: 6px;
  }

  .test-result.success {
    color: #3fb950;
    background: rgba(63, 185, 80, 0.1);
    border: 1px solid rgba(63, 185, 80, 0.3);
  }

  .test-result.error {
    color: #f85149;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid rgba(248, 81, 73, 0.3);
  }

  .model-name { color: var(--text-secondary); }

  .actions {
    display: flex;
    gap: 8px;
    justify-content: flex-end;
  }

  .btn-save {
    background: #238636;
    color: #fff;
    border: none;
    border-radius: 6px;
    padding: 7px 20px;
    font-size: 13px;
    cursor: pointer;
    transition: background 0.15s;
  }

  .btn-save:hover:not(:disabled) { background: #2ea043; }
  .btn-save:disabled { opacity: 0.5; cursor: not-allowed; }

  .btn-test {
    background: transparent;
    color: var(--text-secondary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    padding: 7px 16px;
    font-size: 13px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .btn-test:hover:not(:disabled) {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .btn-test:disabled { opacity: 0.5; cursor: not-allowed; }
</style>
