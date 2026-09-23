<!--
  LogTableGrid
  The scrollable <table> of one page of logs: header, virtually-scrolled data
  rows (LogTableRow) and the expanded row's detail (LogDetailRow). Only the
  rows in view plus a buffer are rendered; padding rows keep the scrollbar
  honest. LogTable owns every piece of state (page, selection, expanded row,
  context, column widths) and resets the scroll position through resetScroll().
-->
<script>
  import LogTableHeader from './LogTableHeader.svelte';
  import LogTableRow from './LogTableRow.svelte';
  import LogDetailRow from './LogDetailRow.svelte';

  let {
    /** Logs on the current page */
    pageLogs,
    /** Visible columns in display order (pinned first) */
    columns,
    /** Ids of the checked rows */
    selectedIds,
    /** Id of the expanded row, or undefined */
    selectedId,
    allSelected = false,
    someSelected = false,
    /** A column resize drag is in progress */
    resizing = false,
    compact = false,
    wrap = true,
    highlightErrors = false,
    timeFormat,
    searchQuery = '',
    /** { [logId]: boolean } */
    contextLoading,
    /** { [logId]: object } */
    contextData,
    /** (log) => void — row click */
    onselect,
    /** (Event, log, index) => void — row checkbox changed; index is within the page */
    oncheck,
    /** () => void */
    ontoggleall,
    /** (MouseEvent, columnId) => void */
    onresizestart,
    /** () => void — scrolled close to the bottom of the page */
    onnearend,
    /** (logId) => void */
    ontogglecontext,
    /** (logId) => void */
    onclosecontext,
    /** (log) => void */
    onexplain,
  } = $props();

  // Virtual scroll
  const ROW_HEIGHT = 36;
  const BUFFER_ROWS = 10;
  let containerHeight = $state(0);
  let scrollTop = $state(0);
  let tableContainer = $state(null);

  const totalItems = $derived(pageLogs.length);
  const visibleCount = $derived(Math.ceil(containerHeight / ROW_HEIGHT) + BUFFER_ROWS * 2);
  const startIndex = $derived(Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - BUFFER_ROWS));
  const endIndex = $derived(Math.min(totalItems, startIndex + visibleCount));
  const visibleItems = $derived(pageLogs.slice(startIndex, endIndex));
  const topPadding = $derived(startIndex * ROW_HEIGHT);
  const bottomPadding = $derived(Math.max(0, (totalItems - endIndex) * ROW_HEIGHT));

  // +1 for the checkbox column
  const colspanCount = $derived(columns.length + 1);

  /** Scroll back to the first row (new result set or page change). */
  export function resetScroll() {
    scrollTop = 0;
    if (tableContainer) tableContainer.scrollTop = 0;
  }

  // Virtual scroll handler — auto-advance page when near bottom
  function handleScroll(e) {
    scrollTop = e.target.scrollTop;
    const { scrollHeight, clientHeight } = e.target;
    if (scrollTop + clientHeight >= scrollHeight - ROW_HEIGHT * 3) {
      onnearend();
    }
  }
</script>

<div
  class="virtual-scroll-container"
  bind:this={tableContainer}
  bind:clientHeight={containerHeight}
  onscroll={handleScroll}
>
  <table class="log-table" class:resizing class:compact class:no-wrap={!wrap}>
    <LogTableHeader
      {columns}
      {allSelected}
      {someSelected}
      {ontoggleall}
      {onresizestart}
    />
    <tbody>
      {#if topPadding > 0}
        <tr class="virtual-padding-row"><td colspan={colspanCount} style="height: {topPadding}px; padding: 0; border: none;"></td></tr>
      {/if}
      <!-- Keyed on the id alone: every row gets a unique one before it reaches
           the store (searchLogs, live tail). A positional fallback shifts under
           every live prepend, and a duplicate key corrupts the reconcile (#117). -->
      {#each visibleItems as log, i (log.id)}
        <LogTableRow
          {log}
          {columns}
          selected={selectedId === log.id}
          checked={selectedIds.has(log.id)}
          {highlightErrors}
          {timeFormat}
          {searchQuery}
          onselect={() => onselect(log)}
          oncheck={(e) => oncheck(e, log, startIndex + i)}
        />

        {#if selectedId === log.id}
          <LogDetailRow
            {log}
            {searchQuery}
            colspan={colspanCount}
            contextLoading={contextLoading[log.id]}
            contextData={contextData[log.id]}
            ontogglecontext={() => ontogglecontext(log.id)}
            onclosecontext={() => onclosecontext(log.id)}
            onexplain={() => onexplain(log)}
          />
        {/if}
      {/each}
      {#if bottomPadding > 0}
        <tr class="virtual-padding-row"><td colspan={colspanCount} style="height: {bottomPadding}px; padding: 0; border: none;"></td></tr>
      {/if}
    </tbody>
  </table>
</div>

<style>
  .virtual-scroll-container {
    flex: 1;
    overflow-y: auto;
    overflow-x: auto;
    position: relative;
    min-height: 0;
  }

  .virtual-scroll-container::-webkit-scrollbar {
    width: 8px;
  }

  /* This scrollbar is styled with off-palette one-offs (#1a1a2e, #333) that
   * appear nowhere else in the app -- most likely a leftover rather than a
   * deliberate choice. Left as literals because a single-use value should not
   * become a token; needs a design decision, not a mechanical swap. */
  .virtual-scroll-container::-webkit-scrollbar-track {
    background: #1a1a2e;
  }

  .virtual-scroll-container::-webkit-scrollbar-thumb {
    background: #333;
    border-radius: 4px;
  }

  .virtual-scroll-container::-webkit-scrollbar-thumb:hover {
    background: #555;
  }

  .virtual-padding-row td {
    padding: 0 !important;
    border: none !important;
  }

  .log-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--text-base);
  }

  .log-table.resizing {
    cursor: col-resize;
    user-select: none;
  }
</style>
