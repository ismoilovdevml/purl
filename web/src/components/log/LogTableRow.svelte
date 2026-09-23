<!--
  LogTableRow
  One data row of the log table: the row checkbox (shift-click range selection
  is resolved by LogTable, which owns the selection) and one LogCell per
  visible column. Clicking anywhere else on the row expands / collapses it.
-->
<script>
  import LogCell from './LogCell.svelte';

  let {
    log,
    /** Visible columns in display order (pinned first) */
    columns,
    /** Row is the expanded one */
    selected = false,
    /** Row checkbox is ticked */
    checked = false,
    /** Tint ERROR / FATAL rows */
    highlightErrors = false,
    timeFormat,
    searchQuery = '',
    /** () => void — row click */
    onselect,
    /** (Event) => void — row checkbox changed */
    oncheck,
  } = $props();

  const isError = $derived(highlightErrors && (log.level === 'ERROR' || log.level === 'FATAL'));

  function stopPropagation(event) {
    event.stopPropagation();
  }
</script>

<tr
  class="log-row"
  class:selected
  class:row-checked={checked}
  class:error-row={isError}
  onclick={onselect}
>
  <!-- Checkbox cell -->
  <td class="checkbox-col" onclick={stopPropagation}>
      <input
      type="checkbox"
      class="row-checkbox"
      {checked}
      onchange={oncheck}
      onclick={stopPropagation}
      aria-label="Select row"
    />
  </td>
  {#each columns as col (col.id)}
    <td
      style={col.width ? `width: ${col.width}px` : ''}
      class:pinned={col.pinned}
    >
      <LogCell {log} column={col.id} {timeFormat} {searchQuery} />
    </td>
  {/each}
</tr>

<style>
  td.pinned {
    background: var(--bg-secondary);
    position: sticky;
    left: 0;
    z-index: 1;
  }

  /* Checkbox column — same box as the header cell styled in LogTableHeader. */
  .checkbox-col {
    width: 36px;
    min-width: 36px;
    max-width: 36px;
    padding: 8px 10px;
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

  .log-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .log-row:hover {
    background: var(--bg-row-hover);
  }

  .log-row:hover td.pinned {
    background: var(--bg-row-hover);
  }

  .log-row.selected {
    background: var(--color-primary-bg-subtle);
  }

  .log-row.selected td.pinned {
    background: var(--color-primary-bg-subtle);
  }

  .log-row.row-checked {
    background: rgba(56, 139, 253, 0.06);
  }

  .log-row.row-checked:hover {
    background: rgba(56, 139, 253, 0.10);
  }

  .log-row.row-checked td.pinned {
    background: rgba(56, 139, 253, 0.06);
  }

  td {
    padding: 8px 12px;
    border-bottom: 1px solid var(--bg-tertiary);
    vertical-align: top;
  }

  /* Compact mode is a class on LogTable's <table>. */
  :global(.log-table.compact) td {
    padding: 4px 10px;
  }

  /* Error highlight */
  .log-row.error-row {
    background: rgba(248, 81, 73, 0.18);
    border-left: 3px solid #f85149;
  }

  .log-row.error-row:hover {
    background: rgba(248, 81, 73, 0.28);
  }

  .log-row.error-row td.pinned {
    background: rgba(248, 81, 73, 0.18);
  }

  .log-row.error-row:hover td.pinned {
    background: rgba(248, 81, 73, 0.28);
  }

  /* Search highlight — the <mark>s LogCell renders via highlightText() */
  :global(.search-highlight) {
    background: var(--color-highlight);
    color: var(--bg-primary);
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }
</style>
