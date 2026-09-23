<!--
  Modal Component
  Reusable modal dialog with overlay

  Usage:
  <Modal bind:open title="Confirm" onclose={() => reset()}>
    <p>Are you sure?</p>
    {#snippet footer()}
      <Button onclick={() => open = false}>Cancel</Button>
      <Button variant="primary">Confirm</Button>
    {/snippet}
  </Modal>

  `open` is only tested for truthiness, so a parent may bind a null|object
  (e.g. "the item being confirmed"); the modal never writes a coerced boolean
  back except `false` on close.
-->
<script>
  import { onDestroy } from 'svelte';
  import { fade, scale } from 'svelte/transition';
  import { trapFocus, FOCUSABLE_SELECTOR, lockScroll, unlockScroll } from '../../utils/dom.js';
  import Icon from './Icon.svelte';
  import { close as closeIcon } from './icons.js';

  let {
    /**
     * Whether modal is open (truthy/falsy). No fallback on purpose: a runes
     * $bindable with a default throws when a parent binds `undefined`.
     */
    open = $bindable(),
    /** Modal title */
    title = '',
    /** @type {'sm' | 'md' | 'lg' | 'xl' | 'full'} */
    size = 'md',
    /** Close on overlay click */
    closeOnOverlay = true,
    /** Close on Escape key */
    closeOnEscape = true,
    /** Show close button */
    showClose = true,
    /** Called after the modal closes itself (close button, overlay, Escape) */
    onclose,
    /** Footer snippet */
    footer,
    children,
  } = $props();

  let modalElement = $state(null);

  /*
   * Deliberately plain `let`, not $state: these are written from inside the
   * focus/scroll effect below, and making them reactive would feed that
   * effect its own writes and trip effect_update_depth_exceeded.
   */
  let previousActiveElement;
  let cleanupTrapFocus;
  let isScrollLocked = false;

  function close() {
    open = false;
    onclose?.();
  }

  function handleOverlayClick(event) {
    if (closeOnOverlay && event.target === event.currentTarget) {
      close();
    }
  }

  function handleKeydown(event) {
    if (!open) return;
    if (closeOnEscape && event.key === 'Escape') {
      close();
    }
  }

  // Only the open/closed transition matters, not which truthy value `open`
  // holds, so an object swapped for another object must not re-run this.
  const isOpen = $derived(!!open);

  // $effect.pre (not $effect) keeps the old reactive-statement ordering: the
  // scroll lock and the saved focus target are settled before the dialog
  // markup is committed.
  $effect.pre(() => {
    if (isOpen) {
      previousActiveElement = document.activeElement;
      if (!isScrollLocked) { lockScroll(); isScrollLocked = true; }

      // Setup focus trap after DOM updates
      setTimeout(() => {
        if (modalElement) {
          cleanupTrapFocus = trapFocus(modalElement);
          // Don't steal focus if user already focused something inside the modal
          if (!modalElement.contains(document.activeElement)) {
            // Prefer inputs/textareas over buttons for initial focus
            const firstInput = modalElement.querySelector('input:not([disabled]), textarea:not([disabled]), select:not([disabled])');
            const target = firstInput || modalElement.querySelector(FOCUSABLE_SELECTOR);
            if (target) {
              target.focus();
            } else {
              modalElement.focus();
            }
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

{#if open}
  <!--
    Two single-code ignores, not one comma-separated list: Svelte 5 runes mode
    needs a comma between codes (a space silently drops all but the first,
    #73), while eslint-plugin-svelte 2.x reads the comma as part of the code
    name and reports the ignore as unused. Separate comments satisfy both.
    Escape is handled on <svelte:window> above; the overlay is a backdrop.
  -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="modal-overlay"
    transition:fade={{ duration: 150 }}
    onclick={handleOverlayClick}
  >
    <div
      class="modal modal-{size}"
      role="dialog"
      aria-modal="true"
      aria-labelledby={title ? 'modal-title' : undefined}
      tabindex="-1"
      bind:this={modalElement}
      transition:scale={{ duration: 150, start: 0.95 }}
    >
      {#if title || showClose}
        <div class="modal-header">
          {#if title}
            <h2 id="modal-title" class="modal-title">{title}</h2>
          {:else}
            <div></div>
          {/if}
          {#if showClose}
            <button
              type="button"
              class="modal-close"
              onclick={close}
              aria-label="Close modal"
            >
              <Icon icon={closeIcon} size={16} />
            </button>
          {/if}
        </div>
      {/if}

      <div class="modal-body">
        {@render children?.()}
      </div>

      {#if footer}
        <div class="modal-footer">
          {@render footer()}
        </div>
      {/if}
    </div>
  </div>
{/if}

<style>
  .modal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: var(--z-modal);
    padding: var(--space-4);
  }

  .modal {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-xl);
    max-height: calc(100vh - 32px);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  /* Sizes */
  .modal-sm {
    width: 100%;
    max-width: 360px;
  }

  .modal-md {
    width: 100%;
    max-width: 480px;
  }

  .modal-lg {
    width: 100%;
    max-width: 640px;
  }

  .modal-xl {
    width: 100%;
    max-width: 800px;
  }

  .modal-full {
    width: calc(100vw - 64px);
    height: calc(100vh - 64px);
    max-width: none;
  }

  .modal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--space-4);
    border-bottom: 1px solid var(--border-color);
    flex-shrink: 0;
  }

  .modal-title {
    font-size: var(--text-lg);
    font-weight: var(--font-semibold);
    color: var(--text-primary);
    margin: 0;
  }

  .modal-close {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    background: transparent;
    border: none;
    border-radius: var(--radius-md);
    color: var(--text-secondary);
    cursor: pointer;
    transition: var(--transition-base);
  }

  .modal-close:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .modal-body {
    padding: var(--space-4);
    overflow-y: auto;
    flex: 1;
  }

  .modal-footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-2);
    padding: var(--space-4);
    border-top: 1px solid var(--border-color);
    flex-shrink: 0;
  }
</style>
