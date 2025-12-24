<!--
  DropdownItem Component
  Individual item within a Dropdown

  Usage:
  <DropdownItem on:click={handleClick}>
    <svg slot="icon">...</svg>
    Menu Item
  </DropdownItem>
-->
<script>
  import { createEventDispatcher } from 'svelte';

  /** Item is active/selected */
  export let active = false;

  /** Item is disabled */
  export let disabled = false;

  /** Item is a danger action */
  export let danger = false;

  const dispatch = createEventDispatcher();

  function handleClick(event) {
    if (!disabled) {
      dispatch('click', event);
    }
  }

  function handleKeydown(event) {
    if ((event.key === 'Enter' || event.key === ' ') && !disabled) {
      event.preventDefault();
      dispatch('click', event);
    }
  }
</script>

<div
  class="dropdown-item"
  class:active
  class:disabled
  class:danger
  role="menuitem"
  tabindex={disabled ? -1 : 0}
  on:click={handleClick}
  on:keydown={handleKeydown}
>
  {#if $$slots.icon}
    <span class="item-icon">
      <slot name="icon" />
    </span>
  {/if}
  <span class="item-content">
    <slot />
  </span>
  {#if $$slots.suffix}
    <span class="item-suffix">
      <slot name="suffix" />
    </span>
  {/if}
</div>

<style>
  .dropdown-item {
    display: flex;
    align-items: center;
    gap: var(--space-2, 8px);
    padding: var(--space-2, 8px) var(--space-3, 12px);
    font-size: var(--text-base, 13px);
    color: var(--text-primary, #c9d1d9);
    cursor: pointer;
    transition: var(--transition-fast, all 0.1s ease);
    user-select: none;
  }

  .dropdown-item:hover:not(.disabled) {
    background: var(--bg-tertiary, #21262d);
  }

  .dropdown-item:focus-visible {
    outline: none;
    background: var(--bg-tertiary, #21262d);
  }

  .dropdown-item.active {
    background: var(--color-primary-bg, #388bfd26);
    color: var(--color-primary, #58a6ff);
  }

  .dropdown-item.disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .dropdown-item.danger {
    color: var(--color-error, #f85149);
  }

  .dropdown-item.danger:hover:not(.disabled) {
    background: var(--color-error-bg, #f8514920);
  }

  .item-icon {
    display: flex;
    align-items: center;
    color: var(--text-secondary, #8b949e);
    flex-shrink: 0;
  }

  .dropdown-item.active .item-icon,
  .dropdown-item.danger .item-icon {
    color: inherit;
  }

  .item-icon :global(svg) {
    width: 16px;
    height: 16px;
  }

  .item-content {
    flex: 1;
    min-width: 0;
  }

  .item-suffix {
    color: var(--text-muted, #6e7681);
    font-size: var(--text-sm, 11px);
    flex-shrink: 0;
  }
</style>
