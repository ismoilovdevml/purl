<!--
  AdvancedDisclosure
  The collapsible "Advanced — ..." block at the bottom of a settings card:
  a chevron button that shows or hides the extra fields. Collapsed on mount.

  Usage:
  <Card padding="md">
    <AdvancedDisclosure label="Advanced — Attribute Mapping">
      ...fields...
    </AdvancedDisclosure>
  </Card>
-->
<script>
  import Icon from './Icon.svelte';
  import { caretDown } from './icons.js';

  let {
    /** Button text */
    label,
    /** The hidden fields (snippet) */
    children,
  } = $props();

  let open = $state(false);
</script>

<button
  type="button"
  class="advanced-toggle"
  onclick={() => open = !open}
>
  <Icon icon={caretDown} size={12} class="chevron {open ? 'open' : ''}" />
  <span>{label}</span>
</button>

{#if open}
  <div class="advanced-body">
    {@render children?.()}
  </div>
{/if}

<style>
  .advanced-toggle {
    display: flex;
    align-items: center;
    gap: 8px;
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    padding: 0;
    transition: color 0.15s ease;
  }

  .advanced-toggle:hover {
    color: var(--text-primary);
  }

  .advanced-toggle :global(.chevron) {
    flex-shrink: 0;
    transition: transform 0.2s ease;
  }

  .advanced-toggle :global(.chevron.open) {
    transform: rotate(180deg);
  }

  .advanced-body {
    margin-top: 16px;
    padding-top: 16px;
    border-top: 1px solid var(--border-color);
  }
</style>
