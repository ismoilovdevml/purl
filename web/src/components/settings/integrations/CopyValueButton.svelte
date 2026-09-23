<!--
  CopyValueButton
  Small square copy button used next to every URL / config line on the
  Integrations page. Shows a check mark while `copied` is true; the page owns
  the clipboard call and the "copied" timer.
-->
<script>
  import Icon from '../../ui/Icon.svelte';
  import { check, copy } from '../../ui/icons.js';

  let {
    /** Text put on the clipboard */
    value,
    /** This value was just copied */
    copied = false,
    /** Tooltip */
    title,
    /** Accessible name */
    label,
    /** (value) => void */
    oncopy,
  } = $props();
</script>

<button
  class="copy-btn"
  onclick={() => oncopy(value)}
  {title}
  aria-label={label}
>
  {#if copied}
    <Icon icon={check} size={14} strokeWidth={2.5} />
  {:else}
    <Icon icon={copy} size={14} strokeWidth={2.5} />
  {/if}
</button>

<style>
  .copy-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 4px;
    color: var(--text-secondary);
    cursor: pointer;
    transition: all 0.15s ease;
    flex-shrink: 0;
  }

  .copy-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
    border-color: var(--text-secondary);
  }
</style>
