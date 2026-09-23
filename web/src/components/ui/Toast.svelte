<!--
  Toast Notification Container
  Displays stacked toast notifications at bottom-right

  Usage:
  import Toast from './ui/Toast.svelte';
  <Toast />

  Trigger toasts via:
  import { success, error, warning, info } from '../stores/toast.js';
  success('Operation completed!');
-->
<script>
  import { fly, fade } from 'svelte/transition';
  import toasts, { removeToast } from '../../stores/toast.js';
  import Icon from './Icon.svelte';
  import { alertTriangle, checkCircle, close, info, xCircle } from './icons.js';

  // Local map of imported glyphs — never `import * as` (see Icon.svelte).
  const TOAST_ICON = { success: checkCircle, error: xCircle, warning: alertTriangle };

  // Limit visible toasts to 5
  const visibleToasts = $derived($toasts.slice(-5));
</script>

{#if visibleToasts.length > 0}
  <div class="toast-container" aria-live="polite" aria-relevant="additions removals">
    {#each visibleToasts as toast (toast.id)}
      <div
        class="toast toast-{toast.type}"
        role="alert"
        in:fly={{ x: 80, duration: 250 }}
        out:fade={{ duration: 150 }}
      >
        <span class="toast-icon">
          <Icon icon={TOAST_ICON[toast.type] ?? info} size={16} />
        </span>
        <span class="toast-message">{toast.message}</span>
        {#if toast.count > 1}
          <span class="toast-count" aria-label="shown {toast.count} times">×{toast.count}</span>
        {/if}
        <button
          class="toast-close"
          onclick={() => removeToast(toast.id)}
          aria-label="Dismiss notification"
        >
          <Icon icon={close} size={14} strokeWidth={2.5} />
        </button>
      </div>
    {/each}
  </div>
{/if}

<style>
  .toast-container {
    position: fixed;
    bottom: 20px;
    right: 20px;
    z-index: 10000;
    display: flex;
    flex-direction: column;
    gap: 8px;
    pointer-events: none;
  }

  .toast {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 16px;
    min-width: 300px;
    max-width: 420px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 8px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    pointer-events: auto;
    font-size: 13px;
    color: #c9d1d9;
  }

  .toast-success {
    border-color: #3fb950;
  }

  .toast-success .toast-icon {
    color: #3fb950;
  }

  .toast-error {
    border-color: #f85149;
  }

  .toast-error .toast-icon {
    color: #f85149;
  }

  .toast-warning {
    border-color: #d29922;
  }

  .toast-warning .toast-icon {
    color: #d29922;
  }

  .toast-info {
    border-color: #58a6ff;
  }

  .toast-info .toast-icon {
    color: #58a6ff;
  }

  .toast-icon {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .toast-message {
    flex: 1;
    line-height: 1.4;
    word-break: break-word;
  }

  .toast-count {
    flex-shrink: 0;
    padding: 1px 6px;
    border-radius: 10px;
    background: rgba(255, 255, 255, 0.08);
    color: #8b949e;
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }

  .toast-close {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    background: none;
    border: none;
    border-radius: 4px;
    color: #8b949e;
    cursor: pointer;
    transition: all 0.15s ease;
    padding: 0;
  }

  .toast-close:hover {
    background: rgba(255, 255, 255, 0.1);
    color: #c9d1d9;
  }

  @media (max-width: 480px) {
    .toast-container {
      left: 12px;
      right: 12px;
      bottom: 12px;
    }

    .toast {
      min-width: auto;
      max-width: none;
    }
  }
</style>
