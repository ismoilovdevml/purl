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

  // Limit visible toasts to 5
  $: visibleToasts = $toasts.slice(-5);
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
          {#if toast.type === 'success'}
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.5"/>
              <path d="M5 8l2 2 4-4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
          {:else if toast.type === 'error'}
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.5"/>
              <path d="M5.5 5.5l5 5M10.5 5.5l-5 5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          {:else if toast.type === 'warning'}
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <path d="M8 1.5l6.5 12H1.5L8 1.5z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>
              <path d="M8 6.5v3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
              <circle cx="8" cy="11.5" r="0.75" fill="currentColor"/>
            </svg>
          {:else}
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.5"/>
              <path d="M8 7v4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
              <circle cx="8" cy="4.75" r="0.75" fill="currentColor"/>
            </svg>
          {/if}
        </span>
        <span class="toast-message">{toast.message}</span>
        <button
          class="toast-close"
          on:click={() => removeToast(toast.id)}
          aria-label="Dismiss notification"
        >
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
            <path d="M3.5 3.5l7 7M10.5 3.5l-7 7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
          </svg>
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
