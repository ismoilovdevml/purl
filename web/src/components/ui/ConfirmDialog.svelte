<!--
  ConfirmDialog Component
  Modal confirmation dialog with danger/warning/info variants

  Usage:
  <ConfirmDialog
    bind:show={showConfirm}
    title="Delete Alert"
    message="Are you sure you want to delete this alert? This action cannot be undone."
    confirmText="Delete"
    variant="danger"
    onConfirm={handleDelete}
  />
-->
<script>
  import { onDestroy } from 'svelte';
  import { fade, scale } from 'svelte/transition';
  import { trapFocus, lockScroll, unlockScroll } from '../../utils/dom.js';

  /** Whether dialog is visible */
  export let show = false;

  /** Dialog title */
  export let title = 'Confirm';

  /** Dialog message */
  export let message = 'Are you sure?';

  /** Confirm button text */
  export let confirmText = 'Confirm';

  /** Cancel button text */
  export let cancelText = 'Cancel';

  /** @type {'danger' | 'warning' | 'info'} */
  export let variant = 'danger';

  /** Callback when confirmed */
  export let onConfirm = () => {};

  /** Callback when cancelled */
  export let onCancel = () => {};

  let dialogElement;
  let confirmButton;
  let previousActiveElement;
  let cleanupTrapFocus;
  let isScrollLocked = false;

  function handleConfirm() {
    show = false;
    onConfirm();
  }

  function handleCancel() {
    show = false;
    onCancel();
  }

  function handleOverlayClick(event) {
    if (event.target === event.currentTarget) {
      handleCancel();
    }
  }

  function handleKeydown(event) {
    if (!show) return;
    if (event.key === 'Escape') {
      handleCancel();
    } else if (event.key === 'Enter') {
      handleConfirm();
    }
  }

  $: if (show) {
    previousActiveElement = document.activeElement;
    if (!isScrollLocked) { lockScroll(); isScrollLocked = true; }

    setTimeout(() => {
      if (dialogElement) {
        cleanupTrapFocus = trapFocus(dialogElement);
        // Don't steal focus if already inside dialog
        if (!dialogElement.contains(document.activeElement)) {
          confirmButton?.focus();
        }
      }
    }, 0);
  } else {
    if (isScrollLocked) { unlockScroll(); isScrollLocked = false; }
    cleanupTrapFocus?.();
    previousActiveElement?.focus();
  }

  onDestroy(() => {
    if (isScrollLocked) unlockScroll();
    cleanupTrapFocus?.();
  });
</script>

<svelte:window on:keydown={handleKeydown} />

{#if show}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div
    class="confirm-overlay"
    transition:fade={{ duration: 150 }}
    on:click={handleOverlayClick}
  >
    <div
      class="confirm-dialog"
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="confirm-title"
      aria-describedby="confirm-message"
      tabindex="-1"
      bind:this={dialogElement}
      transition:scale={{ duration: 150, start: 0.95 }}
    >
      <div class="confirm-icon variant-{variant}">
        {#if variant === 'danger'}
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="10"/>
            <line x1="15" y1="9" x2="9" y2="15"/>
            <line x1="9" y1="9" x2="15" y2="15"/>
          </svg>
        {:else if variant === 'warning'}
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
            <line x1="12" y1="9" x2="12" y2="13"/>
            <line x1="12" y1="17" x2="12.01" y2="17"/>
          </svg>
        {:else}
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="10"/>
            <line x1="12" y1="16" x2="12" y2="12"/>
            <line x1="12" y1="8" x2="12.01" y2="8"/>
          </svg>
        {/if}
      </div>

      <h3 id="confirm-title" class="confirm-title">{title}</h3>
      <p id="confirm-message" class="confirm-message">{message}</p>

      <div class="confirm-actions">
        <button class="btn-cancel" on:click={handleCancel}>
          {cancelText}
        </button>
        <button
          class="btn-confirm variant-{variant}"
          bind:this={confirmButton}
          on:click={handleConfirm}
        >
          {confirmText}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .confirm-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: var(--z-modal, 200);
    padding: 16px;
  }

  .confirm-dialog {
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 12px;
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.6);
    width: 100%;
    max-width: 400px;
    padding: 24px;
    text-align: center;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
  }

  .confirm-icon {
    width: 48px;
    height: 48px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-bottom: 4px;
  }

  .confirm-icon.variant-danger {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
  }

  .confirm-icon.variant-warning {
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
  }

  .confirm-icon.variant-info {
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
  }

  .confirm-title {
    font-size: 16px;
    font-weight: 600;
    color: var(--text-primary, #c9d1d9);
    margin: 0;
  }

  .confirm-message {
    font-size: 13px;
    color: var(--text-secondary, #8b949e);
    margin: 0;
    line-height: 1.5;
  }

  .confirm-actions {
    display: flex;
    gap: 8px;
    width: 100%;
    margin-top: 8px;
  }

  .btn-cancel,
  .btn-confirm {
    flex: 1;
    padding: 8px 16px;
    border-radius: 6px;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s ease;
    border: 1px solid transparent;
  }

  .btn-cancel {
    background: var(--bg-tertiary, #21262d);
    border-color: var(--border-color, #30363d);
    color: var(--text-primary, #c9d1d9);
  }

  .btn-cancel:hover {
    background: var(--bg-hover, #30363d);
    border-color: var(--text-secondary, #8b949e);
  }

  .btn-confirm.variant-danger {
    background: #da3633;
    color: #ffffff;
  }

  .btn-confirm.variant-danger:hover {
    background: #f85149;
  }

  .btn-confirm.variant-warning {
    background: #d29922;
    color: #ffffff;
  }

  .btn-confirm.variant-warning:hover {
    background: #e3b341;
  }

  .btn-confirm.variant-info {
    background: #58a6ff;
    color: #ffffff;
  }

  .btn-confirm.variant-info:hover {
    background: #79b8ff;
  }

  .btn-confirm:focus-visible,
  .btn-cancel:focus-visible {
    outline: 2px solid var(--color-primary, #58a6ff);
    outline-offset: 2px;
  }
</style>
