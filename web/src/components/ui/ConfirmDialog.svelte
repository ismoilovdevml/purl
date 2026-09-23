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
  import Icon from './Icon.svelte';
  // Glyphs, not name strings: Icon takes the imported glyph so icons.js stays
  // tree-shakeable. This file was passing `name="x-circle"`, which Icon has no
  // prop for — `icon` came through undefined and the whole {#if def} block
  // rendered nothing, so the coloured circle at the top of EVERY confirm
  // dialog has been empty since the icon migration.
  import { xCircle, alertTriangle, info } from './icons.js';

  const VARIANT_ICON = { danger: xCircle, warning: alertTriangle, info };

  let {
    /** Whether dialog is visible */
    show = $bindable(false),
    /** Dialog title */
    title = 'Confirm',
    /** Dialog message */
    message = 'Are you sure?',
    /** Confirm button text */
    confirmText = 'Confirm',
    /** Cancel button text */
    cancelText = 'Cancel',
    /** @type {'danger' | 'warning' | 'info'} */
    variant = 'danger',
    /** Callback when confirmed */
    onConfirm = () => {},
    /** Callback when cancelled */
    onCancel = () => {},
  } = $props();

  let dialogElement = $state(null);
  let confirmButton = $state(null);

  /*
   * Deliberately plain `let`, not $state: these are written from inside the
   * focus/scroll effect below, and making them reactive would feed that
   * effect its own writes and trip effect_update_depth_exceeded.
   */
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
    } else if (event.key === 'Enter' && document.activeElement === confirmButton) {
      handleConfirm();
    }
  }

  // $effect.pre (not $effect) keeps the old reactive-statement ordering: the scroll lock and
  // the saved focus target are settled before the dialog markup is committed.
  $effect.pre(() => {
    if (show) {
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
  });

  onDestroy(() => {
    if (isScrollLocked) unlockScroll();
    cleanupTrapFocus?.();
  });
</script>

<svelte:window onkeydown={handleKeydown} />

{#if show}
  <!--
    The overlay is a dimming/positioning layer only, so role="presentation"
    is the honest description: it keeps the backdrop out of the a11y tree
    while the inner role="alertdialog" element stays the exposed dialog.
    That also makes the click handler legitimate without a svelte-ignore —
    no keyboard equivalent is owed here because Escape is handled on
    <svelte:window> above and Cancel is a real focusable button.

    Do NOT go back to a `svelte-ignore` listing two codes separated by a
    space: in runes mode (this component) Svelte 5.45 applies only the FIRST
    code and silently drops the rest, which is how the
    a11y_no_static_element_interactions warning got in here. A comma is
    required if a multi-code ignore is ever needed again.
  -->
  <div
    class="confirm-overlay"
    role="presentation"
    transition:fade={{ duration: 150 }}
    onclick={handleOverlayClick}
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
        <Icon icon={VARIANT_ICON[variant] ?? info} size={24} />
      </div>

      <h3 id="confirm-title" class="confirm-title">{title}</h3>
      <p id="confirm-message" class="confirm-message">{message}</p>

      <div class="confirm-actions">
        <button class="btn-cancel" onclick={handleCancel}>
          {cancelText}
        </button>
        <button
          class="btn-confirm variant-{variant}"
          bind:this={confirmButton}
          onclick={handleConfirm}
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
    z-index: var(--z-modal);
    padding: 16px;
  }

  .confirm-dialog {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
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
    color: var(--text-primary);
    margin: 0;
  }

  .confirm-message {
    font-size: 13px;
    color: var(--text-secondary);
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
    background: var(--bg-tertiary);
    border-color: var(--border-color);
    color: var(--text-primary);
  }

  .btn-cancel:hover {
    background: var(--bg-hover);
    border-color: var(--text-secondary);
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
    outline: 2px solid var(--color-primary);
    outline-offset: 2px;
  }
</style>
