<!--
  HeaderMenu
  A click-to-open dropdown for the logs toolbar (touch-friendly instead of
  hover-only). Closes on a click outside it and on Escape; Escape returns focus
  to the trigger when focus was inside the menu, so it does not fall to <body>
  with the hidden items.

  Usage:
  <HeaderMenu>
    {#snippet label()}Actions{/snippet}
    {#snippet children(close)}
      <button onclick={() => { doThing(); close(); }}>Do thing</button>
    {/snippet}
  </HeaderMenu>
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { chevronDown } from '../ui/icons.js';
  import { fitToViewport } from '../../utils/dom.js';

  /**
   * @type {{
   *   label: import('svelte').Snippet,
   *   children: import('svelte').Snippet<[() => void]>,
   *   selected?: boolean,
   * }}
   */
  let { label, children, selected = false } = $props();

  let open = $state(false);
  let root = $state(null);

  function close() {
    open = false;
  }

  // Capture phase, as before the split: a click inside another component that
  // stops propagation must still close this menu.
  function handleWindowClick(event) {
    if (open && root && !root.contains(event.target)) open = false;
  }

  function handleWindowKeydown(event) {
    if (event.key !== 'Escape' || !open) return;
    open = false;
    if (root && root.contains(document.activeElement)) {
      root.querySelector('.dropdown-trigger')?.focus();
    }
  }
</script>

<svelte:window onclickcapture={handleWindowClick} onkeydown={handleWindowKeydown} />

<div class="actions-dropdown" bind:this={root}>
  <button
    class="btn dropdown-trigger"
    class:btn-selected={selected}
    aria-haspopup="menu"
    aria-expanded={open}
    onclick={() => open = !open}
  >
    {@render label()}
    <Icon icon={chevronDown} size={12} strokeWidth={3} />
  </button>
  <!-- Rendered only while open so fitToViewport measures the real box and can
       pull the menu back inside a narrow viewport (#103). -->
  {#if open}
    <div class="dropdown-menu open" use:fitToViewport>
      {@render children(close)}
    </div>
  {/if}
</div>

<style>
  .actions-dropdown {
    position: relative;
  }

  .btn {
    display: flex;
    align-items: center;
    gap: 6px;
    white-space: nowrap;
    padding: 8px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 14px;
    transition: all 0.2s;
  }

  .btn:hover {
    background: #30363d;
  }

  .btn-selected {
    border-color: #388bfd;
    color: #58a6ff;
  }

  .btn-selected:hover {
    background: rgba(56, 139, 253, 0.1);
  }

  .dropdown-trigger {
    padding-right: 12px;
  }

  .dropdown-trigger :global(svg) {
    opacity: 0.6;
    margin-left: 2px;
  }

  .dropdown-menu {
    position: absolute;
    top: 100%;
    right: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 200;
    min-width: 160px;
    overflow: hidden;
    padding: 4px 0;
  }

  /* :global — the items come from the caller's snippet, so they carry the
     caller's scope class, not this component's. */
  .dropdown-menu :global(button) {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px 14px;
    background: none;
    border: none;
    color: #c9d1d9;
    font-size: 13px;
    cursor: pointer;
    text-align: left;
    transition: background 0.15s;
  }

  .dropdown-menu :global(button:hover) {
    background: #21262d;
  }

  .dropdown-menu :global(button:disabled) {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .dropdown-menu :global(button svg) {
    color: #8b949e;
  }

  .dropdown-menu :global(.divider) {
    height: 1px;
    background: #30363d;
    margin: 4px 0;
  }

  @media (max-width: 480px) {
    .btn {
      padding: 6px 10px;
      font-size: 12px;
    }
  }
</style>
