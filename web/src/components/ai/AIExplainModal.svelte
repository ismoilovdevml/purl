<script>
  import Modal from '../ui/Modal.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import Button from '../ui/Button.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import Icon from '../ui/Icon.svelte';
  import { alertCircle, alertCircleSolid, check } from '../ui/icons.js';
  import {
    aiExplainResult, aiExplainLoading, aiExplainError, explainLog
  } from '../../stores/ai.js';

  export let open = false;
  export let log = null;

  // The explain stores are module-level, so they outlive this modal. Two ways
  // that bites: (1) a run can end without `handleClose` ever firing — a 401
  // routes through clearSession() and unmounts the whole dashboard, so the next
  // mount after a successful re-login opens on a stale "Session expired." and
  // the guard below refuses to send the request; (2) `log` can be swapped while
  // the modal stays mounted, which would show one entry's explanation under
  // another entry's header. Keying the reset on the target log covers both: it
  // runs on mount (null -> id) and on every swap.
  //
  // Declared before the run guard so it clears in the same flush, ahead of it.
  // Its only tracked dependency is `log`; the writes it makes are read nowhere
  // in this statement, so it cannot re-trigger itself.
  let explainTargetKey;
  $: syncExplainTarget(log);

  function syncExplainTarget(target) {
    const key = target ? (target.id ?? null) : null;
    if (key === explainTargetKey) return;
    explainTargetKey = key;
    aiExplainResult.set(null);
    aiExplainError.set(null);
  }

  $: result = $aiExplainResult;
  $: loading = $aiExplainLoading;
  // explainLog() never rejects — it reports failure through this store. The
  // guard below MUST honour it, otherwise a failed run leaves result=null and
  // loading=false and the condition immediately re-fires (unbounded POSTs).
  $: error = $aiExplainError;

  function runExplain() {
    aiExplainError.set(null);
    explainLog(log);
  }

  $: if (open && log && !result && !loading && !error) {
    runExplain();
  }

  function handleClose() {
    open = false;
    aiExplainError.set(null);
    aiExplainResult.set(null);
  }

  function handleRetry() {
    aiExplainResult.set(null);
    runExplain();
  }
</script>

<Modal bind:open title="Explain Log Entry" size="lg" on:close={handleClose}>
  <div class="explain-panel">
    {#if log}
      <div class="log-preview">
        <span class="log-level" class:level-error={['ERROR','CRITICAL','ALERT','EMERGENCY'].includes(log.level)}
              class:level-warn={log.level === 'WARNING' || log.level === 'WARN'}>{log.level}</span>
        <span class="log-service">{log.service}</span>
        <span class="log-message">{log.message}</span>
      </div>
    {/if}

    {#if loading}
      <div class="loading-state">
        <LoadingSpinner />
        <p>AI is analyzing this log entry…</p>
      </div>

    {:else if error}
      <EmptyState icon={alertCircle} title="Could not explain this log" tone="error" size="sm">
        <span slot="description">{error}</span>
        <svelte:fragment slot="actions">
          <Button size="sm" on:click={handleRetry}>Retry</Button>
        </svelte:fragment>
      </EmptyState>

    {:else if result}
      <div class="result-body">

        <!-- Summary -->
        <div class="explain-section">
          <h4 class="section-title">What happened</h4>
          <p class="section-text">{result.summary}</p>
        </div>

        <!-- Possible Causes -->
        {#if result.possible_causes && result.possible_causes.length > 0}
          <div class="explain-section">
            <h4 class="section-title">Possible Causes</h4>
            <ul class="item-list">
              {#each result.possible_causes as cause}
                <li class="item item-cause">
                  <Icon icon={alertCircleSolid} size={12} />
                  {cause}
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        <!-- Suggested Fixes -->
        {#if result.suggested_fixes && result.suggested_fixes.length > 0}
          <div class="explain-section">
            <h4 class="section-title">Suggested Fixes</h4>
            <ul class="item-list">
              {#each result.suggested_fixes as fix}
                <li class="item item-fix">
                  <Icon icon={check} size={12} strokeWidth={3} />
                  {fix}
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        <!-- Related Topics -->
        {#if result.related_topics && result.related_topics.length > 0}
          <div class="explain-section">
            <h4 class="section-title">Related Topics</h4>
            <div class="tags-row">
              {#each result.related_topics as topic}
                <span class="topic-tag">{topic}</span>
              {/each}
            </div>
          </div>
        {/if}
      </div>
    {/if}
  </div>

  <svelte:fragment slot="footer">
    <button class="btn-primary" on:click={handleClose}>Close</button>
  </svelte:fragment>
</Modal>

<style>
  .explain-panel {
    display: flex;
    flex-direction: column;
    gap: 16px;
    min-height: 150px;
  }

  .log-preview {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    padding: 10px 12px;
    flex-wrap: wrap;
  }

  .log-level {
    font-size: 11px;
    font-weight: 700;
    padding: 1px 6px;
    border-radius: 4px;
    background: rgba(139, 148, 158, 0.15);
    color: #8b949e;
    flex-shrink: 0;
  }

  .level-error { background: rgba(248, 81, 73, 0.15); color: #f85149; }
  .level-warn  { background: rgba(210, 153, 34, 0.15); color: #d29922; }

  .log-service {
    font-size: 12px;
    color: #58a6ff;
    flex-shrink: 0;
  }

  .log-message {
    font-size: 13px;
    color: var(--text-primary);
    font-family: var(--font-mono);
    word-break: break-all;
    line-height: 1.4;
  }

  .loading-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    padding: 30px 0;
    color: var(--text-secondary);
    font-size: 14px;
  }

  .result-body {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .explain-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .section-title {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin: 0;
  }

  .section-text {
    font-size: 14px;
    color: var(--text-primary);
    line-height: 1.6;
    margin: 0;
  }

  .item-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .item {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    font-size: 13px;
    padding: 6px 10px;
    border-radius: 6px;
    line-height: 1.5;
  }

  /* :global — the mark is rendered by <Icon>, so it carries that component's
     scope class, not this one's. */
  .item :global(svg) { flex-shrink: 0; margin-top: 2px; }

  .item-cause {
    color: #f0883e;
    background: rgba(240, 136, 62, 0.08);
  }

  .item-fix {
    color: #3fb950;
    background: rgba(63, 185, 80, 0.08);
  }

  .tags-row {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .topic-tag {
    font-size: 12px;
    background: rgba(139, 148, 158, 0.1);
    color: var(--text-secondary);
    border: 1px solid var(--border-color);
    border-radius: 4px;
    padding: 2px 8px;
  }

  .btn-primary {
    background: #238636;
    color: #fff;
    border: none;
    border-radius: 6px;
    padding: 6px 16px;
    font-size: 13px;
    cursor: pointer;
    transition: background 0.15s;
  }

  .btn-primary:hover { background: #2ea043; }
</style>
