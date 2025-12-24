<!--
  LogTable Component
  Main log table with column configuration, selection, and context

  Usage:
  <LogTable logs={logs} />
-->
<script>
  import { onMount, onDestroy } from 'svelte';
  import { query, fetchLogContext, filterByTrace, filterByRequest } from '../../stores/logs.js';
  import { formatTimestamp, formatFullTimestamp } from '../../utils/format.js';
  import { getLevelColor } from '../../utils/colors.js';
  import { highlightText } from '../../utils/dom.js';
  import ColumnPicker from './ColumnPicker.svelte';
  import LogDetail from './LogDetail.svelte';
  import LogContextPanel from './LogContextPanel.svelte';

  export let logs = [];

  // Context state
  let contextData = {};
  let contextLoading = {};

  // Current search query for highlighting
  let searchQuery = '';
  const unsubscribeQuery = query.subscribe(v => searchQuery = v);

  onDestroy(() => {
    unsubscribeQuery();
  });

  let selectedLog = null;
  let showColumnMenu = false;

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

  // Helper to get meta field value
  function getMetaField(log, field) {
    if (!log.meta) return '';
    try {
      const meta = typeof log.meta === 'string' ? JSON.parse(log.meta) : log.meta;
      return meta[field] || '';
    } catch {
      return '';
    }
  }

  $: visibleColumns = columns.filter(c => c.visible);
  $: pinnedColumns = visibleColumns.filter(c => c.pinned);
  $: unpinnedColumns = visibleColumns.filter(c => !c.pinned);
  $: orderedVisibleColumns = [...pinnedColumns, ...unpinnedColumns];
  $: colspanCount = visibleColumns.length;
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
    <div class="empty-state">
      <svg width="48" height="48" viewBox="0 0 48 48">
        <path fill="currentColor" opacity="0.3" d="M24 4C12.954 4 4 12.954 4 24s8.954 20 20 20 20-8.954 20-20S35.046 4 24 4Zm0 36c-8.837 0-16-7.163-16-16S15.163 8 24 8s16 7.163 16 16-7.163 16-16 16Z"/>
        <path fill="currentColor" d="M24 14a2 2 0 0 1 2 2v8a2 2 0 0 1-4 0v-8a2 2 0 0 1 2-2Zm0 16a2 2 0 1 1 0 4 2 2 0 0 1 0-4Z"/>
      </svg>
      <p>No logs found</p>
      <span>Try adjusting your search or time range</span>
    </div>
  {:else}
    <table class="log-table" class:resizing={resizing !== null}>
      <thead>
        <tr>
          {#each orderedVisibleColumns as col}
            <th
              style={col.width ? `width: ${col.width}px` : ''}
              class:pinned={col.pinned}
            >
              {#if col.pinned}
                <svg class="pin-icon" width="10" height="10" viewBox="0 0 16 16">
                  <path fill="currentColor" d="M9.828.722a.5.5 0 0 1 .354.146l4.95 4.95a.5.5 0 0 1 0 .707c-.48.48-1.072.588-1.503.588-.177 0-.335-.018-.46-.039l-3.134 3.134a5.927 5.927 0 0 1 .16 1.013c.046.702-.032 1.687-.72 2.375a.5.5 0 0 1-.707 0l-2.829-2.828-3.182 3.182c-.195.195-1.219.902-1.414.707-.195-.195.512-1.22.707-1.414l3.182-3.182-2.828-2.829a.5.5 0 0 1 0-.707c.688-.688 1.673-.767 2.375-.72a5.922 5.922 0 0 1 1.013.16l3.134-3.133a2.772 2.772 0 0 1-.04-.461c0-.43.108-1.022.589-1.503a.5.5 0 0 1 .353-.146z"/>
                </svg>
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
        {#each logs as log, i (log.id || i)}
          <tr
            class="log-row"
            class:selected={selectedLog?.id === log.id}
            on:click={() => selectLog(log)}
          >
            {#each orderedVisibleColumns as col (col.id)}
              <td
                style={col.width ? `width: ${col.width}px` : ''}
                class:pinned={col.pinned}
              >
                {#if col.id === 'time'}
                  <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
                    {formatTimestamp(log.timestamp)}
                  </span>
                {:else if col.id === 'level'}
                  <span class="level-badge" style="background: {getLevelColor(log.level)}20; color: {getLevelColor(log.level)}">
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
              </td>
            </tr>
          {/if}
        {/each}
      </tbody>
    </table>
  {/if}
</div>

<style>
  .log-table-container {
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-md, 6px);
    overflow: auto;
    max-height: calc(100vh - 280px);
  }

  .table-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: var(--bg-tertiary, #21262d);
    border-bottom: 1px solid var(--border-color, #30363d);
  }

  .toolbar-info {
    font-size: var(--text-sm, 12px);
    color: var(--text-secondary, #8b949e);
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 60px 20px;
    color: var(--text-secondary, #8b949e);
  }

  .empty-state svg {
    margin-bottom: 16px;
    color: var(--border-color, #30363d);
  }

  .empty-state p {
    font-size: var(--text-lg, 16px);
    font-weight: 500;
    margin-bottom: 4px;
  }

  .empty-state span {
    font-size: var(--text-base, 14px);
    color: var(--text-muted, #6e7681);
  }

  .log-table {
    width: 100%;
    border-collapse: collapse;
    font-size: var(--text-base, 13px);
  }

  thead {
    background: var(--bg-tertiary, #21262d);
    position: sticky;
    top: 0;
    z-index: 2;
  }

  th {
    padding: 10px 12px;
    text-align: left;
    font-weight: 500;
    color: var(--text-secondary, #8b949e);
    border-bottom: 1px solid var(--border-color, #30363d);
    white-space: nowrap;
    position: relative;
    user-select: none;
  }

  th.pinned,
  td.pinned {
    background: var(--bg-tertiary, #21262d);
    position: sticky;
    left: 0;
    z-index: 1;
  }

  td.pinned {
    background: var(--bg-secondary, #161b22);
  }

  th .pin-icon {
    margin-right: 4px;
    color: var(--color-primary, #58a6ff);
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
    background: var(--color-primary, #58a6ff);
  }

  .log-table.resizing {
    cursor: col-resize;
    user-select: none;
  }

  .log-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .log-row:hover {
    background: var(--bg-row-hover, #1c2128);
  }

  .log-row:hover td.pinned {
    background: var(--bg-row-hover, #1c2128);
  }

  .log-row.selected {
    background: var(--color-primary-bg, rgba(56, 139, 253, 0.08));
  }

  .log-row.selected td.pinned {
    background: var(--color-primary-bg, rgba(56, 139, 253, 0.08));
  }

  td {
    padding: 8px 12px;
    border-bottom: 1px solid var(--bg-tertiary, #21262d);
    vertical-align: top;
  }

  .timestamp {
    font-family: var(--font-mono, 'SFMono-Regular', Consolas, monospace);
    color: var(--text-secondary, #8b949e);
  }

  .level-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: var(--radius-sm, 4px);
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .service {
    color: var(--color-primary, #58a6ff);
  }

  .host {
    color: var(--color-purple, #a371f7);
  }

  .namespace {
    color: var(--color-orange, #f0883e);
  }

  .pod {
    color: var(--color-success, #3fb950);
    font-family: var(--font-mono, 'SFMono-Regular', Consolas, monospace);
    font-size: var(--text-sm, 12px);
  }

  .node {
    color: var(--color-purple, #a371f7);
  }

  .message {
    font-family: var(--font-mono, 'SFMono-Regular', Consolas, monospace);
    word-break: break-all;
    color: var(--text-primary, #c9d1d9);
  }

  .detail-row td {
    padding: 0;
    background: var(--bg-primary, #0d1117);
  }

  /* Search highlight */
  :global(.search-highlight) {
    background: var(--color-warning, #f5a623);
    color: var(--bg-primary, #0d1117);
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }
</style>
