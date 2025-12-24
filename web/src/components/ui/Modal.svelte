<!--
  Modal Component
  Reusable modal dialog with overlay

  Usage:
  <Modal bind:open title="Confirm">
    <p>Are you sure?</p>
    <svelte:fragment slot="footer">
      <Button on:click={() => open = false}>Cancel</Button>
      <Button variant="primary">Confirm</Button>
    </svelte:fragment>
  </Modal>
-->
<script>
  import { createEventDispatcher, onDestroy } from 'svelte';
  import { fade, scale } from 'svelte/transition';
  import { trapFocus } from '../../utils/dom.js';

  /** Whether modal is open */
  export let open = false;

  /** Modal title */
  export let title = '';

  /** @type {'sm' | 'md' | 'lg' | 'xl' | 'full'} */
  export let size = 'md';

  /** Close on overlay click */
  export let closeOnOverlay = true;

  /** Close on Escape key */
  export let closeOnEscape = true;

  /** Show close button */
  export let showClose = true;

  const dispatch = createEventDispatcher();

  let modalElement;
  let previousActiveElement;
  let cleanupTrapFocus;

  function close() {
    open = false;
    dispatch('close');
  }

  function handleOverlayClick(event) {
    if (closeOnOverlay && event.target === event.currentTarget) {
      close();
    }
  }

  function handleKeydown(event) {
    if (closeOnEscape && event.key === 'Escape') {
      close();
    }
  }

  $: if (open) {
    previousActiveElement = document.activeElement;
    document.body.style.overflow = 'hidden';

    // Setup focus trap after DOM updates
    setTimeout(() => {
      if (modalElement) {
        cleanupTrapFocus = trapFocus(modalElement);
        const firstFocusable = modalElement.querySelector(
          'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
        );
        firstFocusable?.focus();
      }
    }, 0);
  } else {
    document.body.style.overflow = '';
    cleanupTrapFocus?.();
    previousActiveElement?.focus();
  }

  onDestroy(() => {
    document.body.style.overflow = '';
    cleanupTrapFocus?.();
  });
</script>

<svelte:window on:keydown={handleKeydown} />

{#if open}
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div
    class="modal-overlay"
    transition:fade={{ duration: 150 }}
    on:click={handleOverlayClick}
  >
    <div
      class="modal modal-{size}"
      role="dialog"
      aria-modal="true"
      aria-labelledby={title ? 'modal-title' : undefined}
      tabindex="-1"
      bind:this={modalElement}
      transition:scale={{ duration: 150, start: 0.95 }}
      on:click|stopPropagation
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
              on:click={close}
              aria-label="Close modal"
            >
              <svg width="16" height="16" viewBox="0 0 16 16">
                <path fill="currentColor" d="M3.72 3.72a.75.75 0 0 1 1.06 0L8 6.94l3.22-3.22a.75.75 0 1 1 1.06 1.06L9.06 8l3.22 3.22a.75.75 0 1 1-1.06 1.06L8 9.06l-3.22 3.22a.75.75 0 0 1-1.06-1.06L6.94 8 3.72 4.78a.75.75 0 0 1 0-1.06Z"/>
              </svg>
            </button>
          {/if}
        </div>
      {/if}

      <div class="modal-body">
        <slot />
      </div>

      {#if $$slots.footer}
        <div class="modal-footer">
          <slot name="footer" />
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
    z-index: var(--z-modal, 200);
    padding: var(--space-4, 16px);
  }

  .modal {
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--border-radius-lg, 8px);
    box-shadow: var(--shadow-xl, 0 12px 40px rgba(0, 0, 0, 0.6));
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
    padding: var(--space-4, 16px);
    border-bottom: 1px solid var(--border-color, #30363d);
    flex-shrink: 0;
  }

  .modal-title {
    font-size: var(--text-lg, 16px);
    font-weight: var(--font-semibold, 600);
    color: var(--text-primary, #c9d1d9);
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
    border-radius: var(--border-radius, 6px);
    color: var(--text-secondary, #8b949e);
    cursor: pointer;
    transition: var(--transition-base, all 0.15s ease);
  }

  .modal-close:hover {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .modal-body {
    padding: var(--space-4, 16px);
    overflow-y: auto;
    flex: 1;
  }

  .modal-footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-2, 8px);
    padding: var(--space-4, 16px);
    border-top: 1px solid var(--border-color, #30363d);
    flex-shrink: 0;
  }
</style>
