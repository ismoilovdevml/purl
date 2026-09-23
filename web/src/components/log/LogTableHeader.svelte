<!--
  LogTableHeader
  The <thead> of the log table: the select-all checkbox (indeterminate while
  only part of the page is checked) and one header cell per visible column,
  each with a drag handle for resizing. Resizing itself is tracked by LogTable,
  which owns the column widths.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { pinAngle } from '../ui/icons.js';

  let {
    /** Visible columns in display order (pinned first) */
    columns,
    /** Every row on the current page is checked */
    allSelected = false,
    /** Some, but not all, rows on the current page are checked */
    someSelected = false,
    /** () => void */
    ontoggleall,
    /** (MouseEvent, columnId) => void — mousedown on a resize handle */
    onresizestart,
  } = $props();

  // Apply indeterminate state to header checkbox via action
  function indeterminate(node, value) {
    node.indeterminate = value;
    return {
      update(newValue) {
        node.indeterminate = newValue;
      }
    };
  }
</script>

<thead>
  <tr>
    <!-- Checkbox column header -->
    <th class="checkbox-col">
      <input
        type="checkbox"
        class="row-checkbox"
        checked={allSelected}
        use:indeterminate={someSelected}
        onchange={ontoggleall}
        aria-label="Select all on current page"
      />
    </th>
    {#each columns as col}
      <th
        style={col.width ? `width: ${col.width}px` : ''}
        class:pinned={col.pinned}
      >
        {#if col.pinned}
          <Icon icon={pinAngle} size={10} class="pin-icon" label="Pinned column" />
        {/if}
        {col.label}
        {#if col.id !== 'message'}
          <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
          <div
            class="resize-handle"
            role="separator"
            aria-orientation="vertical"
            tabindex="-1"
            onmousedown={(e) => onresizestart(e, col.id)}
          ></div>
        {/if}
      </th>
    {/each}
  </tr>
</thead>

<style>
  thead {
    background: var(--bg-tertiary);
    position: sticky;
    top: 0;
    z-index: 2;
  }

  th {
    padding: 10px 12px;
    text-align: left;
    font-weight: 500;
    color: var(--text-secondary);
    border-bottom: 1px solid var(--border-color);
    white-space: nowrap;
    position: relative;
    user-select: none;
  }

  th.pinned {
    background: var(--bg-tertiary);
    position: sticky;
    left: 0;
    z-index: 1;
  }

  /* :global — rendered by <Icon>, so the scoping class never lands on the svg. */
  th :global(.pin-icon) {
    margin-right: 4px;
    color: var(--color-primary);
    vertical-align: middle;
  }

  .resize-handle {
    position: absolute;
    right: 0;
    top: 0;
    bottom: 0;
    width: 4px;
    cursor: col-resize;
    background: transparent;
    transition: background 0.15s;
  }

  /* `.resizing` is set on LogTable's <table> while a drag is in progress. */
  .resize-handle:hover,
  :global(.log-table.resizing) .resize-handle {
    background: var(--color-primary);
  }

  /* Checkbox column — same box as the body cells styled in LogTable. */
  .checkbox-col {
    width: 36px;
    min-width: 36px;
    max-width: 36px;
    padding: 10px 10px;
    text-align: center;
    vertical-align: middle;
  }

  .row-checkbox {
    width: 14px;
    height: 14px;
    cursor: pointer;
    accent-color: var(--color-primary);
    vertical-align: middle;
  }

  /* Compact mode is a class on LogTable's <table>. */
  :global(.log-table.compact) th {
    padding: 6px 10px;
  }
</style>
