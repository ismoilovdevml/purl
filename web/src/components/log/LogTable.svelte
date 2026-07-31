<!--
  LogTable Component
  Main log table with column configuration, selection, and context

  Usage:
  <LogTable logs={logs} />
-->
<script>
  import { onMount, onDestroy, createEventDispatcher, tick } from 'svelte';
  import {
    query, error as searchError, searchLogs, fetchLogContext, filterByTrace, filterByRequest
  } from '../../stores/logs.js';
  import { formatTimestamp, formatFullTimestamp } from '../../utils/format.js';
  import { getLevelColor, getLevelBgColor } from '../../utils/colors.js';
  import { highlightText } from '../../utils/dom.js';
  import { compactMode, lineWrap, highlightErrors, showHost, timestampFormat, maxResults, clampMaxResults } from '../../stores/settings.js';
  import ColumnPicker from './ColumnPicker.svelte';
  import LogDetail from './LogDetail.svelte';
  import LogContextPanel from './LogContextPanel.svelte';
  import AIAnalysisPanel from '../ai/AIAnalysisPanel.svelte';
  import AIExplainModal from '../ai/AIExplainModal.svelte';
  import { aiEnabled, aiConfigured } from '../../stores/ai.js';
  import Icon from '../ui/Icon.svelte';
  import Button from '../ui/Button.svelte';
  import {
    alertCircle, alertCircleSolid, box, chevronLeft, chevronRight, close, fileText, pinAngle, search
  } from '../ui/icons.js';
  import EmptyState from '../ui/EmptyState.svelte';
  import IngestSnippet from '../onboarding/IngestSnippet.svelte';
  import { hasEverIngested, refreshIngestState } from '../../stores/ingest.js';

  export let logs = [];

  const dispatch = createEventDispatcher();

  // Settings
  let isCompact = false;
  let shouldWrap = true;
  let shouldHighlightErrors = true;
  let timeFormat = 'absolute';
  let maxResultsValue = 500;

  // Subscription references (initialized in onMount)
  let unsubscribeCompact = null;
  let unsubscribeWrap = null;
  let unsubscribeHighlight = null;
  let unsubscribeTimeFormat = null;
  let unsubscribeHost = null;
  let unsubscribeQuery = null;
  let unsubscribeMaxResults = null;

  // Context state
  let contextData = {};
  let contextLoading = {};

  // Current search query for highlighting
  let searchQuery = '';

  let selectedLog = null;
  let showColumnMenu = false;

  // AI state
  let showAnalysisPanel = false;
  let showExplainModal = false;
  let logToExplain = null;

  // Pagination
  const pageSize = 100;
  let currentPage = 1;

  // Virtual scroll
  const ROW_HEIGHT = 36;
  const BUFFER_ROWS = 10;
  let containerHeight = 0;
  let scrollTop = 0;
  let tableContainer;

  // Multi-row selection
  let selectedIds = new Set();
  let lastCheckedIndex = null;

  // Column configuration
  let columns = [
    { id: 'time', label: 'Time', visible: true, width: 90, minWidth: 60, group: 'core', pinned: false },
    { id: 'level', label: 'Level', visible: true, width: 100, minWidth: 60, group: 'core', pinned: false },
    { id: 'service', label: 'Service', visible: true, width: 150, minWidth: 80, group: 'core', pinned: false },
    { id: 'host', label: 'Host', visible: false, width: 120, minWidth: 80, group: 'core', pinned: false },
    { id: 'namespace', label: 'Namespace', visible: false, width: 120, minWidth: 80, meta: true, group: 'kubernetes', pinned: false },
    { id: 'pod', label: 'Pod', visible: false, width: 180, minWidth: 100, meta: true, group: 'kubernetes', pinned: false },
    { id: 'node', label: 'Node', visible: false, width: 150, minWidth: 100, meta: true, group: 'kubernetes', pinned: false },
    { id: 'message', label: 'Message', visible: true, width: null, minWidth: 200, group: 'core', pinned: false }
  ];

  // Resize state
  let resizing = null;
  let startX = 0;
  let startWidth = 0;

  onMount(() => {
    // Decides which empty state to draw when a result set comes back empty:
    // "you have never sent a log" vs "your filter matched nothing". Cheap,
    // cached and never throws, so it is safe to fire unconditionally.
    refreshIngestState();

    // Initialize subscriptions
    unsubscribeCompact = compactMode.subscribe(v => isCompact = v);
    unsubscribeWrap = lineWrap.subscribe(v => shouldWrap = v);
    unsubscribeHighlight = highlightErrors.subscribe(v => shouldHighlightErrors = v);
    unsubscribeTimeFormat = timestampFormat.subscribe(v => timeFormat = v);
    unsubscribeQuery = query.subscribe(v => searchQuery = v);
    // Clamped: this value is rendered ("Showing max N logs") and compared
    // against the row count, so an out-of-range setting must not reach the UI.
    unsubscribeMaxResults = maxResults.subscribe(v => maxResultsValue = clampMaxResults(v));
    unsubscribeHost = showHost.subscribe(v => {
      // Update host column visibility when setting changes
      const hostCol = columns.find(c => c.id === 'host');
      if (hostCol && hostCol.visible !== v) {
        hostCol.visible = v;
        columns = columns;
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
    if (unsubscribeQuery) unsubscribeQuery();
    if (unsubscribeCompact) unsubscribeCompact();
    if (unsubscribeWrap) unsubscribeWrap();
    if (unsubscribeHighlight) unsubscribeHighlight();
    if (unsubscribeHost) unsubscribeHost();
    if (unsubscribeTimeFormat) unsubscribeTimeFormat();
    if (unsubscribeMaxResults) unsubscribeMaxResults();
  });

  // Reset pagination, selection, and scroll when logs array changes
  $: if (logs) {
    currentPage = 1;
    selectedIds = new Set();
    lastCheckedIndex = null;
    scrollTop = 0;
    if (tableContainer) tableContainer.scrollTop = 0;
    // Defer dispatch outside reactive tracking scope to prevent
    // parent handler from capturing $logs as a dependency of this effect
    tick().then(() => dispatch('selectionChange', { selected: [] }));
  }

  // Derived: paginated slice
  $: paginatedLogs = logs.slice((currentPage - 1) * pageSize, currentPage * pageSize);

  // Derived: total pages
  $: totalPages = Math.max(1, Math.ceil(logs.length / pageSize));

  // Derived: page range display
  $: pageStart = logs.length === 0 ? 0 : (currentPage - 1) * pageSize + 1;
  $: pageEnd = Math.min(currentPage * pageSize, logs.length);

  // Virtual scroll: derived values from paginated logs
  $: totalItems = paginatedLogs.length;
  $: visibleCount = Math.ceil(containerHeight / ROW_HEIGHT) + BUFFER_ROWS * 2;
  $: startIndex = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - BUFFER_ROWS);
  $: endIndex = Math.min(totalItems, startIndex + visibleCount);
  $: visibleItems = paginatedLogs.slice(startIndex, endIndex);
  $: topPadding = startIndex * ROW_HEIGHT;
  $: bottomPadding = Math.max(0, (totalItems - endIndex) * ROW_HEIGHT);

  // Derived: selection state for current page
  $: allSelected = paginatedLogs.length > 0 && paginatedLogs.every(l => selectedIds.has(l.id));
  $: someSelected = paginatedLogs.some(l => selectedIds.has(l.id)) && !allSelected;
  $: selectionCount = selectedIds.size;

  // Virtual scroll handler — auto-advance page when near bottom
  function handleScroll(e) {
    scrollTop = e.target.scrollTop;
    const { scrollHeight, clientHeight } = e.target;
    if (currentPage < totalPages && scrollTop + clientHeight >= scrollHeight - ROW_HEIGHT * 3) {
      goToNextPage();
    }
  }

  function saveColumnConfig() {
    localStorage.setItem('purl_column_config', JSON.stringify(
      columns.map(c => ({ id: c.id, visible: c.visible, width: c.width, pinned: c.pinned }))
    ));
  }

  function handleColumnChange(event) {
    columns = event.detail.columns;
    saveColumnConfig();
  }

  function selectLog(log) {
    selectedLog = selectedLog?.id === log.id ? null : log;
  }

  async function loadContext(logId) {
    if (contextData[logId]) {
      delete contextData[logId];
      contextData = contextData;
      return;
    }

    contextLoading[logId] = true;
    contextLoading = contextLoading;

    const data = await fetchLogContext(logId, 50, 50);

    contextLoading[logId] = false;
    contextLoading = contextLoading;

    if (data) {
      contextData[logId] = data;
      contextData = contextData;
    }
  }

  function closeContext(logId) {
    delete contextData[logId];
    contextData = contextData;
  }

  function handleFilterTrace(event) {
    filterByTrace(event.detail.traceId);
  }

  function handleFilterRequest(event) {
    filterByRequest(event.detail.requestId);
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
    columns = columns;
  }

  function stopResize() {
    if (resizing) {
      saveColumnConfig();
    }
    resizing = null;
    document.removeEventListener('mousemove', handleResize);
    document.removeEventListener('mouseup', stopResize);
  }

  // Helper to get meta field value - use pre-parsed meta if available
  function getMetaField(log, field) {
    // Use pre-parsed meta from logs.js if available
    if (log.parsedMeta) {
      return log.parsedMeta[field] || '';
    }
    if (!log.meta) return '';
    try {
      const meta = typeof log.meta === 'string' ? JSON.parse(log.meta) : log.meta;
      return meta[field] || '';
    } catch {
      return '';
    }
  }

  // Consolidated reactive block to avoid cascade recalculations
  let visibleColumns = [];
  let pinnedColumns = [];
  let unpinnedColumns = [];
  let orderedVisibleColumns = [];
  let colspanCount = 0;

  $: {
    visibleColumns = columns.filter(c => c.visible);
    pinnedColumns = visibleColumns.filter(c => c.pinned);
    unpinnedColumns = visibleColumns.filter(c => !c.pinned);
    orderedVisibleColumns = [...pinnedColumns, ...unpinnedColumns];
    // +1 for the checkbox column
    colspanCount = visibleColumns.length + 1;
  }

  // Pagination controls
  function goToPrevPage() {
    if (currentPage > 1) {
      currentPage -= 1;
      scrollTop = 0;
      if (tableContainer) tableContainer.scrollTop = 0;
    }
  }

  function goToNextPage() {
    if (currentPage < totalPages) {
      currentPage += 1;
      scrollTop = 0;
      if (tableContainer) tableContainer.scrollTop = 0;
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
    dispatch('selectionChange', { selected: [...selectedIds] });
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
    dispatch('selectionChange', { selected: [...selectedIds] });
  }

  function clearSelection() {
    selectedIds = new Set();
    lastCheckedIndex = null;
    dispatch('selectionChange', { selected: [] });
  }

  function exportSelected() {
    const selected = logs.filter(l => selectedIds.has(l.id));
    if (selected.length === 0) return;

    const headers = ['timestamp', 'level', 'service', 'host', 'message'];
    const csvRows = [headers.join(',')];

    for (const log of selected) {
      const row = headers.map(h => {
        const val = log[h] || '';
        const escaped = String(val).replace(/"/g, '""');
        return /[,\r\n"]/.test(escaped) ? `"${escaped}"` : escaped;
      });
      csvRows.push(row.join(','));
    }

    const blob = new Blob([csvRows.join('\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `purl-selected-${Date.now()}.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

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

<div class="log-table-container">
  <!-- Toolbar -->
  <div class="table-toolbar">
    <ColumnPicker
      bind:columns
      bind:open={showColumnMenu}
      on:change={handleColumnChange}
    />
    <span class="toolbar-info">{logs.length} logs</span>
  </div>

  {#if logs.length === 0}
    <!--
      Three very different empty results. `$searchError` means the last search
      never produced a result set at all (rejected query, server down) — saying
      "no logs found" there would report a broken query as an answer.
      `$hasEverIngested === false` means this instance has never received a
      single line, so search advice is useless and the user needs onboarding.
      `true` (and `null` = not known) keep the original meaning — never guess
      "you have no logs" on an unknown probe.
    -->
    {#if $searchError}
      <EmptyState icon={alertCircle} title="Search failed" tone="error">
        <span slot="description">{$searchError}</span>
        <svelte:fragment slot="actions">
          <Button size="sm" on:click={searchLogs}>Retry search</Button>
        </svelte:fragment>
      </EmptyState>
    {:else if $hasEverIngested === false}
      <EmptyState icon={box} title="No logs yet" tone="accent">
        <span slot="description">
          Purl has not received any logs from this instance yet. Point a log source at it and
          they will show up here.
        </span>
        <svelte:fragment slot="actions">
          <a class="onboard-btn" href="#settings/agents">Set up a log source</a>
          <a
            class="onboard-link"
            href="https://purlogs.com/docs"
            target="_blank"
            rel="noopener noreferrer"
          >Read the docs</a>
        </svelte:fragment>
        <svelte:fragment slot="extra">
          <IngestSnippet />
        </svelte:fragment>
      </EmptyState>
    {:else}
      <EmptyState icon={search} title="No logs found">
        Try adjusting your search or time range.
      </EmptyState>
    {/if}
  {:else}
    <!-- Selection bar -->
    {#if selectionCount > 0}
      <div class="selection-bar">
        <span class="selection-count"><strong>{selectionCount}</strong> {selectionCount === 1 ? 'row' : 'rows'} selected</span>
        <button class="selection-action-btn" on:click={exportSelected}>
          <Icon icon={fileText} size={12} strokeWidth={3} />
          Export selected
        </button>
        {#if $aiEnabled && $aiConfigured}
          <button class="selection-action-btn ai-analyze-btn" on:click={() => { showAnalysisPanel = true; }}>
            <Icon icon={alertCircleSolid} size={12} />
            AI Analyze
          </button>
        {/if}
        <button class="selection-clear-btn" on:click={clearSelection}>
          <Icon icon={close} size={12} strokeWidth={3} />
          Clear selection
        </button>
      </div>
    {/if}

    <div
      class="virtual-scroll-container"
      bind:this={tableContainer}
      bind:clientHeight={containerHeight}
      on:scroll={handleScroll}
    >
      <table class="log-table" class:resizing={resizing !== null} class:compact={isCompact} class:no-wrap={!shouldWrap}>
        <thead>
          <tr>
            <!-- Checkbox column header -->
            <th class="checkbox-col">
                <input
                type="checkbox"
                class="row-checkbox"
                checked={allSelected}
                use:indeterminate={someSelected}
                on:change={toggleSelectAll}
                aria-label="Select all on current page"
              />
            </th>
            {#each orderedVisibleColumns as col}
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
                    on:mousedown={(e) => startResize(e, col.id)}
                  ></div>
                {/if}
              </th>
            {/each}
          </tr>
        </thead>
        <tbody>
          {#if topPadding > 0}
            <tr class="virtual-padding-row"><td colspan={colspanCount} style="height: {topPadding}px; padding: 0; border: none;"></td></tr>
          {/if}
          {#each visibleItems as log, i (log.id || startIndex + i)}
            <tr
              class="log-row"
              class:selected={selectedLog?.id === log.id}
              class:row-checked={selectedIds.has(log.id)}
              class:error-row={shouldHighlightErrors && (log.level === 'ERROR' || log.level === 'FATAL')}
              on:click={() => selectLog(log)}
            >
              <!-- Checkbox cell -->
              <td class="checkbox-col" on:click|stopPropagation>
                  <input
                  type="checkbox"
                  class="row-checkbox"
                  checked={selectedIds.has(log.id)}
                  on:change={(e) => toggleRowSelection(e, log, startIndex + i)}
                  on:click|stopPropagation
                  aria-label="Select row"
                />
              </td>
              {#each orderedVisibleColumns as col (col.id)}
                <td
                  style={col.width ? `width: ${col.width}px` : ''}
                  class:pinned={col.pinned}
                >
                  {#if col.id === 'time'}
                    <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
                      {formatTimestamp(log.timestamp, timeFormat)}
                    </span>
                  {:else if col.id === 'level'}
                    <span class="level-badge" style="background: {getLevelBgColor(log.level)}; color: {getLevelColor(log.level)}">
                      {log.level}
                    </span>
                  {:else if col.id === 'service'}
                    <span class="service">{log.service}</span>
                  {:else if col.id === 'host'}
                    <span class="host">{log.host}</span>
                  {:else if col.id === 'namespace'}
                    <span class="namespace">{getMetaField(log, 'namespace')}</span>
                  {:else if col.id === 'pod'}
                    <span class="pod">{getMetaField(log, 'pod')}</span>
                  {:else if col.id === 'node'}
                    <span class="node">{getMetaField(log, 'node')}</span>
                  {:else if col.id === 'message'}
                    <!-- eslint-disable-next-line svelte/no-at-html-tags -->
                    <span class="message">{@html highlightText(log.message, searchQuery)}</span>
                  {/if}
                </td>
              {/each}
            </tr>

            {#if selectedLog?.id === log.id}
              <tr class="detail-row">
                <td colspan={colspanCount}>
                  <LogDetail
                    {log}
                    {searchQuery}
                    contextLoading={contextLoading[log.id]}
                    contextOpen={!!contextData[log.id]}
                    on:filterTrace={handleFilterTrace}
                    on:filterRequest={handleFilterRequest}
                    on:showContext={() => loadContext(log.id)}
                  >
                    <svelte:fragment slot="context">
                      {#if contextData[log.id]}
                        <LogContextPanel
                          currentLog={log}
                          beforeLogs={contextData[log.id].before_logs}
                          afterLogs={contextData[log.id].after_logs}
                          beforeCount={contextData[log.id].before_count}
                          afterCount={contextData[log.id].after_count}
                          on:close={() => closeContext(log.id)}
                        />
                      {/if}
                    </svelte:fragment>
                  </LogDetail>
                  {#if $aiEnabled && $aiConfigured}
                    <div class="ai-explain-bar">
                      <button class="ai-explain-btn" on:click|stopPropagation={() => { logToExplain = log; showExplainModal = true; }}>
                        <Icon icon={alertCircleSolid} size={12} />
                        Explain with AI
                      </button>
                    </div>
                  {/if}
                </td>
              </tr>
            {/if}
          {/each}
          {#if bottomPadding > 0}
            <tr class="virtual-padding-row"><td colspan={colspanCount} style="height: {bottomPadding}px; padding: 0; border: none;"></td></tr>
          {/if}
        </tbody>
      </table>
    </div>

    <!-- Pagination footer -->
    <div class="pagination-footer">
      <span class="pagination-info">
        {#if logs.length > 0}
          Showing {pageStart}–{pageEnd} of {logs.length} results
        {/if}
        {#if logs.length >= maxResultsValue}
          <span class="truncation-note">Results may be truncated. Showing max {maxResultsValue} logs.</span>
        {/if}
      </span>
      <div class="pagination-controls">
        <button
          class="page-btn"
          on:click={goToPrevPage}
          disabled={currentPage === 1}
          aria-label="Previous page"
        >
          <Icon icon={chevronLeft} size={14} strokeWidth={3} />
          Prev
        </button>
        <span class="page-indicator">Page {currentPage} of {totalPages}</span>
        <button
          class="page-btn"
          on:click={goToNextPage}
          disabled={currentPage === totalPages}
          aria-label="Next page"
        >
          Next
          <Icon icon={chevronRight} size={14} strokeWidth={3} />
        </button>
      </div>
    </div>
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

  /* Selection bar */
  .selection-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 7px 12px;
    background: var(--color-primary-bg-subtle);
    border-bottom: 1px solid var(--color-primary);
    font-size: var(--text-sm);
  }

  .selection-count {
    color: var(--text-primary);
    margin-right: 4px;
  }

  .selection-count strong {
    color: var(--color-primary);
  }

  .selection-action-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 10px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: var(--text-sm);
    cursor: pointer;
    transition: background 0.15s;
  }

  .selection-action-btn:hover {
    background: var(--border-color);
  }

  .selection-clear-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 10px;
    background: transparent;
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: var(--text-sm);
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }

  .selection-clear-btn:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  /* Onboarding empty state (never-ingested instance) */
  .onboard-btn {
    display: inline-flex;
    align-items: center;
    padding: 6px 14px;
    background: var(--color-primary);
    border: 1px solid var(--color-primary);
    border-radius: var(--radius-sm);
    color: var(--bg-primary);
    font-size: var(--text-sm);
    font-weight: 600;
    text-decoration: none;
  }

  .onboard-btn:hover {
    filter: brightness(1.1);
  }

  .onboard-link {
    display: inline-flex;
    align-items: center;
    padding: 6px 14px;
    background: transparent;
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: var(--text-sm);
    text-decoration: none;
  }

  .onboard-link:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .log-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--text-base);
  }

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

  th.pinned,
  td.pinned {
    background: var(--bg-tertiary);
    position: sticky;
    left: 0;
    z-index: 1;
  }

  td.pinned {
    background: var(--bg-secondary);
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

  .resize-handle:hover,
  .log-table.resizing .resize-handle {
    background: var(--color-primary);
  }

  .log-table.resizing {
    cursor: col-resize;
    user-select: none;
  }

  /* Checkbox column */
  .checkbox-col {
    width: 36px;
    min-width: 36px;
    max-width: 36px;
    padding: 8px 10px;
    text-align: center;
    vertical-align: middle;
  }

  th.checkbox-col {
    padding: 10px 10px;
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

  .timestamp {
    font-family: var(--font-mono);
    color: var(--text-secondary);
  }

  .level-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: var(--radius-sm);
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .service {
    color: var(--color-primary);
  }

  .host {
    color: var(--color-purple);
  }

  .namespace {
    color: var(--color-orange);
  }

  .pod {
    color: var(--color-success);
    font-family: var(--font-mono);
    font-size: var(--text-sm);
  }

  .node {
    color: var(--color-purple);
  }

  .message {
    font-family: var(--font-mono);
    word-break: break-all;
    color: var(--text-primary);
  }

  .detail-row td {
    padding: 0;
    background: var(--bg-primary);
  }

  /* Search highlight */
  :global(.search-highlight) {
    background: var(--color-highlight);
    color: var(--bg-primary);
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }

  /* Compact mode */
  .log-table.compact th {
    padding: 6px 10px;
  }

  .log-table.compact td {
    padding: 4px 10px;
  }

  .log-table.compact .level-badge {
    padding: 1px 6px;
    font-size: 10px;
  }

  /* No wrap mode */
  .log-table.no-wrap .message {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 600px;
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

  /* Pagination footer */
  .pagination-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: var(--bg-tertiary);
    border-top: 1px solid var(--border-color);
    font-size: var(--text-sm);
    color: var(--text-secondary);
    position: sticky;
    bottom: 0;
    z-index: 2;
  }

  .pagination-info {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .truncation-note {
    color: var(--color-highlight);
    font-size: 11px;
  }

  .pagination-controls {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .page-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px 10px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: var(--text-sm);
    cursor: pointer;
    transition: background 0.15s;
  }

  .page-btn:hover:not(:disabled) {
    background: var(--border-color);
  }

  .page-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .page-indicator {
    font-size: var(--text-sm);
    color: var(--text-secondary);
    min-width: 80px;
    text-align: center;
  }

  .ai-analyze-btn {
    background: rgba(163, 113, 247, 0.1);
    border-color: rgba(163, 113, 247, 0.4);
    color: #a371f7;
  }

  .ai-analyze-btn:hover {
    background: rgba(163, 113, 247, 0.2);
  }

  .ai-explain-bar {
    padding: 6px 12px;
    border-top: 1px solid var(--bg-tertiary);
    background: var(--bg-primary);
  }

  .ai-explain-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 10px;
    background: rgba(163, 113, 247, 0.08);
    border: 1px solid rgba(163, 113, 247, 0.3);
    border-radius: var(--radius-sm);
    color: #a371f7;
    font-size: var(--text-sm);
    cursor: pointer;
    transition: background 0.15s;
  }

  .ai-explain-btn:hover {
    background: rgba(163, 113, 247, 0.15);
  }
</style>
