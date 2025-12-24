<!--
  Dropdown Component
  Reusable dropdown menu with click outside handling

  Usage:
  <Dropdown bind:open>
    <Button slot="trigger">Open Menu</Button>
    <DropdownItem on:click={handleAction}>Action</DropdownItem>
  </Dropdown>
-->
<script>
  import { createEventDispatcher } from 'svelte';
  import { scale } from 'svelte/transition';
  import { clickOutside } from '../../utils/dom.js';

  /** Whether dropdown is open */
  export let open = false;

  /** @type {'bottom-left' | 'bottom-right' | 'top-left' | 'top-right'} */
  export let position = 'bottom-left';

  /** Close when clicking inside */
  export let closeOnSelect = true;

  /** Minimum width of dropdown */
  export let minWidth = '180px';

  /** Maximum height of dropdown */
  export let maxHeight = '300px';

  const dispatch = createEventDispatcher();

  let containerRef;

  function toggle() {
    open = !open;
    dispatch(open ? 'open' : 'close');
  }

  function close() {
    if (open) {
      open = false;
      dispatch('close');
    }
  }

  function handleKeydown(event) {
    if (event.key === 'Escape' && open) {
      close();
    }
  }

  function handleSelect() {
    if (closeOnSelect) {
      close();
    }
  }
</script>

<svelte:window on:keydown={handleKeydown} />

<div
  class="dropdown"
  bind:this={containerRef}
  use:clickOutside
  on:clickOutside={close}
>
  <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
  <div class="dropdown-trigger" on:click|stopPropagation={toggle}>
    <slot name="trigger" {open} {toggle} />
  </div>

  {#if open}
    <div
      class="dropdown-menu dropdown-{position}"
      style="min-width: {minWidth}; max-height: {maxHeight};"
      role="menu"
      tabindex="-1"
      transition:scale={{ duration: 100, start: 0.95 }}
      on:click={handleSelect}
      on:keydown={handleKeydown}
    >
      <slot />
    </div>
  {/if}
</div>

<style>
  .dropdown {
    position: relative;
    display: inline-block;
  }

  .dropdown-trigger {
    display: inline-block;
  }

  .dropdown-menu {
    position: absolute;
    z-index: var(--z-dropdown, 50);
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--border-radius-lg, 8px);
    box-shadow: var(--shadow-lg, 0 8px 24px rgba(0, 0, 0, 0.5));
    overflow-y: auto;
    padding: var(--space-1, 4px) 0;
  }

  /* Positions */
  .dropdown-bottom-left {
    top: 100%;
    left: 0;
    margin-top: var(--space-1, 4px);
  }

  .dropdown-bottom-right {
    top: 100%;
    right: 0;
    margin-top: var(--space-1, 4px);
  }

  .dropdown-top-left {
    bottom: 100%;
    left: 0;
    margin-bottom: var(--space-1, 4px);
  }

  .dropdown-top-right {
    bottom: 100%;
    right: 0;
    margin-bottom: var(--space-1, 4px);
  }
</style>
