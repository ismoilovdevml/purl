<!--
  LogTable Component
  Main log table with column configuration, selection, and context

  Usage:
  <LogTable logs={$logs} onselectionchange={({ selected }) => ...} />

  Split into: LogTableEmpty (zero-row states), LogSelectionBar, LogTableGrid
  (the virtually-scrolled table: LogTableHeader, LogTableRow, LogDetailRow)
  and LogPagination.
-->
<script>
  import { onMount, onDestroy, tick, untrack } from 'svelte';
  import { query, fetchLogContext } from '../../stores/logs.js';
  import { compactMode, lineWrap, highlightErrors, showHost, timestampFormat, maxResults, clampMaxResults } from '../../stores/settings.js';
  import ColumnPicker from './ColumnPicker.svelte';
  import LogTableGrid from './LogTableGrid.svelte';
  import LogSelectionBar from './LogSelectionBar.svelte';
  import LogPagination from './LogPagination.svelte';
  import LogTableEmpty from './LogTableEmpty.svelte';
  import AIAnalysisPanel from '../ai/AIAnalysisPanel.svelte';
  import AIExplainModal from '../ai/AIExplainModal.svelte';
  import { refreshIngestState } from '../../stores/ingest.js';
  import { defaultColumns } from '../../utils/columns.js';
  import { downloadLogsCsv } from '../../utils/csv.js';

  let {
    logs = [],
    /** ({ selected }) — ids of the checked rows, after every change */
    onselectionchange,
  } = $props();

  // Clamped: this value is rendered ("Showing max N logs") and compared
  // against the row count, so an out-of-range setting must not reach the UI.
  const maxResultsValue = $derived(clampMaxResults($maxResults));

  let unsubscribeHost = null;

  // Context state
  let contextData = $state({});
  let contextLoading = $state({});

  let selectedLog = $state.raw(null);
  let showColumnMenu = $state(false);

  // AI state
  let showAnalysisPanel = $state(false);
  let showExplainModal = $state(false);
  let logToExplain = $state.raw(null);

  // Pagination
  const pageSize = 100;
  let currentPage = $state(1);

  // The table itself (virtual scroll lives there); used to reset its scroll
  let grid = $state(null);

  // Multi-row selection
  let selectedIds = $state.raw(new Set());
  let lastCheckedIndex = null;

  // Column configuration
  let columns = $state(defaultColumns());

  // Resize state
  let resizing = $state(null);
  let startX = 0;
  let startWidth = 0;

  onMount(() => {
    // Decides which empty state to draw when a result set comes back empty:
    // "you have never sent a log" vs "your filter matched nothing". Cheap,
    // cached and never throws, so it is safe to fire unconditionally.
    refreshIngestState();

    unsubscribeHost = showHost.subscribe(v => {
      // Update host column visibility when setting changes
      const hostCol = columns.find(c => c.id === 'host');
      if (hostCol && hostCol.visible !== v) {
        hostCol.visible = v;
        saveColumnConfig();
      }
    });

    // Load saved column config
    const saved = localStorage.getItem('purl_column_config');
    if (saved) {
      try {
        const parsed = JSON.parse(saved);
        columns = columns.map(col => ({
          ...col,
          ...parsed.find(p => p.id === col.id)
        }));
      } catch {
        // Ignore parse errors
      }
    }
  });

  onDestroy(() => {
    if (unsubscribeHost) unsubscribeHost();
  });

  // Reset pagination, selection, and scroll when logs array changes
  $effect.pre(() => {
    if (!logs) return;
    untrack(() => {
      currentPage = 1;
      selectedIds = new Set();
      lastCheckedIndex = null;
      grid?.resetScroll();
    });
    // Deferred so the parent's handler runs outside this effect and cannot
    // pick up its own stores as dependencies of it.
    tick().then(() => onselectionchange?.({ selected: [] }));
  });

  // Derived: paginated slice
  const paginatedLogs = $derived(logs.slice((currentPage - 1) * pageSize, currentPage * pageSize));

  // Derived: total pages
  const totalPages = $derived(Math.max(1, Math.ceil(logs.length / pageSize)));

  // Derived: page range display
  const pageStart = $derived(logs.length === 0 ? 0 : (currentPage - 1) * pageSize + 1);
  const pageEnd = $derived(Math.min(currentPage * pageSize, logs.length));

  // Derived: selection state for current page
  const allSelected = $derived(paginatedLogs.length > 0 && paginatedLogs.every(l => selectedIds.has(l.id)));
  const someSelected = $derived(paginatedLogs.some(l => selectedIds.has(l.id)) && !allSelected);
  const selectionCount = $derived(selectedIds.size);

  // Visible columns, pinned ones first
  const visibleColumns = $derived(columns.filter(c => c.visible));
  const orderedVisibleColumns = $derived([
    ...visibleColumns.filter(c => c.pinned),
    ...visibleColumns.filter(c => !c.pinned),
  ]);

  function saveColumnConfig() {
    localStorage.setItem('purl_column_config', JSON.stringify(
      columns.map(c => ({ id: c.id, visible: c.visible, width: c.width, pinned: c.pinned }))
    ));
  }

  function handleColumnChange(detail) {
    columns = detail.columns;
    saveColumnConfig();
  }

  function selectLog(log) {
    selectedLog = selectedLog?.id === log.id ? null : log;
  }

  async function loadContext(logId) {
    if (contextData[logId]) {
      delete contextData[logId];
      return;
    }

    contextLoading[logId] = true;

    const data = await fetchLogContext(logId, 50, 50);

    contextLoading[logId] = false;

    if (data) {
      contextData[logId] = data;
    }
  }

  function closeContext(logId) {
    delete contextData[logId];
  }

  function startResize(event, colId) {
    event.preventDefault();
    const col = columns.find(c => c.id === colId);
    if (!col || col.id === 'message') return;

    resizing = colId;
    startX = event.clientX;
    startWidth = col.width;

    document.addEventListener('mousemove', handleResize);
    document.addEventListener('mouseup', stopResize);
  }

  function handleResize(event) {
    if (!resizing) return;
    const col = columns.find(c => c.id === resizing);
    if (!col) return;

    const delta = event.clientX - startX;
    col.width = Math.max(col.minWidth, startWidth + delta);
  }

  function stopResize() {
    if (resizing) {
      saveColumnConfig();
    }
    resizing = null;
    document.removeEventListener('mousemove', handleResize);
    document.removeEventListener('mouseup', stopResize);
  }

  // Pagination controls
  function goToPrevPage() {
    if (currentPage > 1) {
      currentPage -= 1;
      grid?.resetScroll();
    }
  }

  function goToNextPage() {
    if (currentPage < totalPages) {
      currentPage += 1;
      grid?.resetScroll();
    }
  }

  // Selection handlers
  function toggleRowSelection(event, log, index) {
    event.stopPropagation();
    const newSet = new Set(selectedIds);

    if (event.shiftKey && lastCheckedIndex !== null) {
      // Range select between lastCheckedIndex and current index
      const from = Math.min(lastCheckedIndex, index);
      const to = Math.max(lastCheckedIndex, index);
      const shouldSelect = !newSet.has(log.id);
      for (let i = from; i <= to; i++) {
        const l = paginatedLogs[i];
        if (l) {
          if (shouldSelect) {
            newSet.add(l.id);
          } else {
            newSet.delete(l.id);
          }
        }
      }
    } else {
      if (newSet.has(log.id)) {
        newSet.delete(log.id);
      } else {
        newSet.add(log.id);
      }
      lastCheckedIndex = index;
    }

    selectedIds = newSet;
    onselectionchange?.({ selected: [...selectedIds] });
  }

  function toggleSelectAll() {
    const newSet = new Set(selectedIds);
    if (allSelected) {
      // Deselect all on current page
      for (const l of paginatedLogs) {
        newSet.delete(l.id);
      }
    } else {
      // Select all on current page
      for (const l of paginatedLogs) {
        newSet.add(l.id);
      }
    }
    selectedIds = newSet;
    onselectionchange?.({ selected: [...selectedIds] });
  }

  function clearSelection() {
    selectedIds = new Set();
    lastCheckedIndex = null;
    onselectionchange?.({ selected: [] });
  }

  function exportSelected() {
    const selected = logs.filter(l => selectedIds.has(l.id));
    if (selected.length === 0) return;
    downloadLogsCsv(selected, 'purl-selected');
  }
</script>

<div class="log-table-container">
  <!-- Toolbar -->
  <div class="table-toolbar">
    <ColumnPicker
      bind:columns
      bind:open={showColumnMenu}
      onchange={handleColumnChange}
    />
    <span class="toolbar-info">{logs.length} logs</span>
  </div>

  {#if logs.length === 0}
    <LogTableEmpty />
  {:else}
    {#if selectionCount > 0}
      <LogSelectionBar
        count={selectionCount}
        onexport={exportSelected}
        onanalyze={() => { showAnalysisPanel = true; }}
        onclear={clearSelection}
      />
    {/if}

    <LogTableGrid
      bind:this={grid}
      pageLogs={paginatedLogs}
      columns={orderedVisibleColumns}
      {selectedIds}
      selectedId={selectedLog?.id}
      {allSelected}
      {someSelected}
      resizing={resizing !== null}
      compact={$compactMode}
      wrap={$lineWrap}
      highlightErrors={$highlightErrors}
      timeFormat={$timestampFormat}
      searchQuery={$query}
      {contextLoading}
      {contextData}
      onselect={selectLog}
      oncheck={toggleRowSelection}
      ontoggleall={toggleSelectAll}
      onresizestart={startResize}
      onnearend={goToNextPage}
      ontogglecontext={loadContext}
      onclosecontext={closeContext}
      onexplain={(log) => { logToExplain = log; showExplainModal = true; }}
    />

    <LogPagination
      total={logs.length}
      {pageStart}
      {pageEnd}
      {currentPage}
      {totalPages}
      maxResults={maxResultsValue}
      onprev={goToPrevPage}
      onnext={goToNextPage}
    />
  {/if}

  <!-- AI Modals -->
  {#if showAnalysisPanel}
    <AIAnalysisPanel
      bind:open={showAnalysisPanel}
      selectedLogs={logs.filter(l => selectedIds.has(l.id))}
    />
  {/if}
  {#if showExplainModal && logToExplain}
    <AIExplainModal
      bind:open={showExplainModal}
      log={logToExplain}
    />
  {/if}
</div>

<style>
  .log-table-container {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    overflow: hidden;
    max-height: calc(100vh - 280px);
    display: flex;
    flex-direction: column;
  }

  .table-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: var(--bg-tertiary);
    border-bottom: 1px solid var(--border-color);
  }

  .toolbar-info {
    font-size: var(--text-sm);
    color: var(--text-secondary);
  }
</style>
