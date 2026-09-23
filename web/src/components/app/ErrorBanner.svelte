<!--
  ErrorBanner
  The dismissible banner under the app header that surfaces a failed log
  search, with Retry. Auto-hides after 10 seconds.
-->
<script>
  import { onDestroy, untrack } from 'svelte';
  import Icon from '../ui/Icon.svelte';
  import { alertCircleSolid, close } from '../ui/icons.js';
  import { error, searchLogs } from '../../stores/logs.js';

  // Enhanced error state with retry callback and severity
  let errorState = $state.raw({ message: '', retryFn: null, severity: 'error' });
  let errorDismissTimer = null;

  // Which `$error` value the user (or the auto-dismiss timer) already sent away.
  // This is the loop-breaker. The banner and the `error` store have different
  // lifetimes on purpose — the store must stay set so LogTable knows its rows
  // are not an answer to the current query — so dismissal cannot be expressed by
  // clearing the store. Instead the sync below remembers what was dismissed and
  // refuses to raise it a second time. Reset whenever the store goes null (i.e.
  // a new search started), so the same message from a NEW failure shows again.
  let dismissedMessage = null;

  // Sync the logs store error into the banner (retry defaults to searchLogs).
  // `$error` is the only tracked dependency: the sync runs untracked, so the
  // writes it makes to `errorState` cannot re-trigger it. Tracking `errorState`
  // is what previously made dismissal impossible — clearError() wrote the
  // tracked dependency, the sync re-ran in the same flush, `$error` was still
  // set, and the banner was rebuilt before paint.
  $effect.pre(() => {
    const storeError = $error;
    untrack(() => syncBannerWithStoreError(storeError));
  });

  function syncBannerWithStoreError(storeError) {
    if (storeError) {
      if (storeError === dismissedMessage) return;
      setError(storeError, searchLogs, 'error');
      return;
    }
    dismissedMessage = null;
    if (errorState.message && errorState.retryFn === searchLogs) clearError();
  }

  function setError(message, retryFn = null, severity = 'error') {
    // Avoid redundant re-renders: skip if the same error is already displayed
    if (errorState.message === message && errorState.severity === severity) return;
    if (errorDismissTimer) clearTimeout(errorDismissTimer);
    errorState = { message, retryFn, severity };
    // Auto-dismiss after 10 seconds
    errorDismissTimer = setTimeout(() => {
      dismissError();
    }, 10000);
  }

  // User-initiated (X button) or timer-initiated hide. Records the message so
  // the store→banner sync does not raise it again while `$error` still holds it.
  function dismissError() {
    if (errorState.message && errorState.message === $error) {
      dismissedMessage = errorState.message;
    }
    clearError();
  }

  // Hides the BANNER only. The `error` store is deliberately left alone: it is
  // also what tells the log table that the current rows are not an answer to the
  // current query, and that stays true after the banner is gone. The store is
  // cleared by the next search (searchLogs sets it to null on entry).
  function clearError() {
    if (errorDismissTimer) {
      clearTimeout(errorDismissTimer);
      errorDismissTimer = null;
    }
    errorState = { message: '', retryFn: null, severity: 'error' };
  }

  onDestroy(() => {
    if (errorDismissTimer) clearTimeout(errorDismissTimer);
  });
</script>

{#if errorState.message}
  <div class="error-banner severity-{errorState.severity}" role="alert">
    <Icon icon={alertCircleSolid} size={16} />
    <span>{errorState.message}</span>
    {#if errorState.retryFn}
      <button class="retry-btn" onclick={() => errorState.retryFn()} aria-label="Retry">
        Retry
      </button>
    {/if}
    <button
      class="dismiss-btn"
      onclick={dismissError}
      aria-label="Dismiss error"
    >
      <Icon icon={close} size={14} strokeWidth={3} />
    </button>
  </div>
{/if}

<style>
  .error-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 16px;
    background: rgba(248, 81, 73, 0.1);
    border-bottom: 1px solid #f85149;
    color: #f85149;
    font-size: 13px;
  }

  .error-banner.severity-warning {
    background: rgba(210, 153, 34, 0.1);
    border-bottom-color: #d29922;
    color: #d29922;
  }

  .error-banner.severity-info {
    background: rgba(56, 139, 253, 0.1);
    border-bottom-color: rgba(56, 139, 253, 0.3);
    color: #58a6ff;
  }

  .error-banner :global(svg) {
    flex-shrink: 0;
  }

  .error-banner span {
    flex: 1;
  }

  .retry-btn {
    padding: 4px 10px;
    background: rgba(248, 81, 73, 0.15);
    border: 1px solid rgba(248, 81, 73, 0.4);
    border-radius: 4px;
    color: #f85149;
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    flex-shrink: 0;
  }

  .retry-btn:hover {
    background: rgba(248, 81, 73, 0.25);
  }

  .error-banner.severity-warning .retry-btn {
    background: rgba(210, 153, 34, 0.15);
    border-color: rgba(210, 153, 34, 0.4);
    color: #d29922;
  }

  .error-banner.severity-warning .retry-btn:hover {
    background: rgba(210, 153, 34, 0.25);
  }

  .dismiss-btn {
    padding: 4px;
    background: none;
    border: none;
    color: #f85149;
    cursor: pointer;
    border-radius: 4px;
    opacity: 0.7;
    transition: opacity 0.15s;
    flex-shrink: 0;
  }

  .dismiss-btn:hover {
    opacity: 1;
    background: rgba(248, 81, 73, 0.2);
  }

  .error-banner.severity-warning .dismiss-btn {
    color: #d29922;
  }

  .error-banner.severity-warning .dismiss-btn:hover {
    background: rgba(210, 153, 34, 0.2);
  }

  .error-banner.severity-info .dismiss-btn {
    color: #58a6ff;
  }

  .error-banner.severity-info .dismiss-btn:hover {
    background: rgba(56, 139, 253, 0.2);
  }
</style>
