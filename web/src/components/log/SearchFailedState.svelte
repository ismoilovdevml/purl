<!--
  SearchFailedState
  The log table's "Search failed" state (#107): the user-safe message, Retry,
  a copyable support reference, and — when the server said how long an outage
  will last (`retry_after` / Retry-After) — one automatic retry after that
  wait, with a visible countdown. One per failure: a new failure (new
  `$searchError` / `$errorDetail`) restarts the countdown.
-->
<svelte:options runes />

<script>
  import { onDestroy } from 'svelte';
  import { error as searchError, errorDetail, searchLogs } from '../../stores/logs.js';
  import { copyToClipboard } from '../../utils/dom.js';
  import { success as toastSuccess } from '../../stores/toast.js';
  import EmptyState from '../ui/EmptyState.svelte';
  import Button from '../ui/Button.svelte';
  import { alertCircle } from '../ui/icons.js';

  let secondsLeft = $state(null);
  let timer = null;

  function stopCountdown() {
    if (timer) clearInterval(timer);
    timer = null;
    secondsLeft = null;
  }

  // Re-armed only by a new failure: `$errorDetail` is replaced on every
  // search, so the same outage failing again schedules one more retry.
  $effect(() => {
    const wait = $errorDetail.retryAfter;
    stopCountdown();
    if (!wait) return;
    secondsLeft = wait;
    timer = setInterval(() => {
      secondsLeft -= 1;
      if (secondsLeft <= 0) {
        stopCountdown();
        searchLogs();
      }
    }, 1000);
    return stopCountdown;
  });

  onDestroy(stopCountdown);

  function retryNow() {
    stopCountdown();
    searchLogs();
  }

  async function copyReference() {
    if (await copyToClipboard($errorDetail.requestId)) toastSuccess('Reference copied');
  }
</script>

<EmptyState icon={alertCircle} title="Search failed" tone="error">
  {#snippet description()}<span>{$searchError}</span>{/snippet}
  {#snippet actions()}
    <Button size="sm" onclick={retryNow}>Retry search</Button>
  {/snippet}
  {#snippet extra()}
    <div class="failure-meta">
      {#if secondsLeft}
        <span class="auto-retry" role="status">Retrying automatically in {secondsLeft}s</span>
      {/if}
      {#if $errorDetail.requestId}
        <!-- The server log holds the full detail under this reference. -->
        <button class="request-id" onclick={copyReference} title="Copy reference for support">
          Reference: <code>{$errorDetail.requestId}</code>
        </button>
      {/if}
    </div>
  {/snippet}
</EmptyState>

<style>
  .failure-meta {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space-2);
  }

  .auto-retry {
    color: var(--text-muted);
    font-size: var(--text-xs);
  }

  .request-id {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 2px 8px;
    background: none;
    border: 1px dashed var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-muted);
    font-size: var(--text-xs);
    cursor: copy;
  }

  .request-id:hover {
    color: var(--text-secondary);
  }

  .request-id code {
    font-family: var(--font-mono);
  }
</style>
