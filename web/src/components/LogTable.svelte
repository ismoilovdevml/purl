<script>
  import { onMount, onDestroy } from 'svelte';
  import { formatTimestamp, formatFullTimestamp, getLevelColor, query, fetchLogContext } from '../stores/logs.js';
  import { highlightText } from '../lib/utils.js';
  import TableToolbar from './logtable/TableToolbar.svelte';
  import EmptyState from './logtable/EmptyState.svelte';
  import LogDetailPanel from './logtable/LogDetailPanel.svelte';

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

  // Column configuration with resizable widths
  let columns = [
    { id: 'time', label: 'Time', visible: true, width: 90, minWidth: 60 },
    { id: 'level', label: 'Level', visible: true, width: 100, minWidth: 60 },
    { id: 'service', label: 'Service', visible: true, width: 150, minWidth: 80 },
    { id: 'host', label: 'Host', visible: false, width: 120, minWidth: 80 },
    { id: 'namespace', label: 'Namespace', visible: false, width: 120, minWidth: 80, meta: true },
    { id: 'pod', label: 'Pod', visible: false, width: 180, minWidth: 100, meta: true },
    { id: 'node', label: 'Node', visible: false, width: 150, minWidth: 100, meta: true },
    { id: 'message', label: 'Message', visible: true, width: null, minWidth: 200 }
  ];

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
      columns.map(c => ({ id: c.id, visible: c.visible, width: c.width }))
    ));
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

  function handleToggleColumn(event) {
    const colId = event.detail;
    columns = columns.map(c =>
      c.id === colId ? { ...c, visible: !c.visible } : c
    );
    saveColumnConfig();
  }

  function handleResetColumns() {
    columns = [
      { id: 'time', label: 'Time', visible: true, width: 90, minWidth: 60 },
      { id: 'level', label: 'Level', visible: true, width: 100, minWidth: 60 },
      { id: 'service', label: 'Service', visible: true, width: 150, minWidth: 80 },
      { id: 'host', label: 'Host', visible: false, width: 120, minWidth: 80 },
      { id: 'namespace', label: 'Namespace', visible: false, width: 120, minWidth: 80, meta: true },
      { id: 'pod', label: 'Pod', visible: false, width: 180, minWidth: 100, meta: true },
      { id: 'node', label: 'Node', visible: false, width: 150, minWidth: 100, meta: true },
      { id: 'message', label: 'Message', visible: true, width: null, minWidth: 200 }
    ];
    saveColumnConfig();
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

  $: visibleColumns = columns.filter(c => c.visible);
  $: colspanCount = visibleColumns.length;
</script>

<div class="log-table-container">
  <TableToolbar
    {columns}
    logsCount={logs.length}
    on:toggleColumn={handleToggleColumn}
    on:resetColumns={handleResetColumns}
  />

  {#if logs.length === 0}
    <EmptyState />
  {:else}
    <table class="log-table" class:resizing={resizing !== null}>
      <thead>
        <tr>
          {#each visibleColumns as col}
            <th style={col.width ? `width: ${col.width}px` : ''}>
              {col.label}
              {#if col.id !== 'message'}
                <!-- svelte-ignore a11y-no-noninteractive-element-interactions -->
                <div class="resize-handle" role="separator" aria-orientation="vertical" tabindex="-1" on:mousedown={(e) => startResize(e, col.id)}></div>
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
            {#if columns.find(c => c.id === 'time')?.visible}
              <td style="width: {columns.find(c => c.id === 'time').width}px">
                <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
                  {formatTimestamp(log.timestamp)}
                </span>
              </td>
            {/if}
            {#if columns.find(c => c.id === 'level')?.visible}
              <td style="width: {columns.find(c => c.id === 'level').width}px">
                <span class="level-badge" style="background: {getLevelColor(log.level)}20; color: {getLevelColor(log.level)}">
                  {log.level}
                </span>
              </td>
            {/if}
            {#if columns.find(c => c.id === 'service')?.visible}
              <td style="width: {columns.find(c => c.id === 'service').width}px">
                <span class="service">{log.service}</span>
              </td>
            {/if}
            {#if columns.find(c => c.id === 'host')?.visible}
              <td style="width: {columns.find(c => c.id === 'host').width}px">
                <span class="host">{log.host}</span>
              </td>
            {/if}
            {#if columns.find(c => c.id === 'namespace')?.visible}
              <td style="width: {columns.find(c => c.id === 'namespace').width}px">
                <span class="namespace">{getMetaField(log, 'namespace')}</span>
              </td>
            {/if}
            {#if columns.find(c => c.id === 'pod')?.visible}
              <td style="width: {columns.find(c => c.id === 'pod').width}px">
                <span class="pod">{getMetaField(log, 'pod')}</span>
              </td>
            {/if}
            {#if columns.find(c => c.id === 'node')?.visible}
              <td style="width: {columns.find(c => c.id === 'node').width}px">
                <span class="node">{getMetaField(log, 'node')}</span>
              </td>
            {/if}
            {#if columns.find(c => c.id === 'message')?.visible}
              <td>
                <!-- eslint-disable-next-line svelte/no-at-html-tags -->
                <span class="message">{@html highlightText(log.message, searchQuery)}</span>
              </td>
            {/if}
          </tr>

          {#if selectedLog?.id === log.id}
            <tr class="detail-row">
              <td colspan={colspanCount}>
                <LogDetailPanel
                  {log}
                  {searchQuery}
                  contextData={contextData[log.id]}
                  contextLoading={contextLoading[log.id]}
                  onLoadContext={() => loadContext(log.id)}
                  onCloseContext={() => closeContext(log.id)}
                />
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
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    overflow: auto;
    max-height: calc(100vh - 280px);
  }

  .log-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }

  thead {
    background: #21262d;
    position: sticky;
    top: 0;
  }

  th {
    padding: 10px 12px;
    text-align: left;
    font-weight: 500;
    color: #8b949e;
    border-bottom: 1px solid #30363d;
    white-space: nowrap;
    position: relative;
    user-select: none;
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
    background: #58a6ff;
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
    background: #1c2128;
  }

  .log-row.selected {
    background: #388bfd15;
  }

  td {
    padding: 8px 12px;
    border-bottom: 1px solid #21262d;
    vertical-align: top;
  }

  .timestamp {
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #8b949e;
  }

  .level-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .service {
    color: #58a6ff;
  }

  .host {
    color: #a371f7;
  }

  .namespace {
    color: #f0883e;
  }

  .pod {
    color: #3fb950;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
  }

  .node {
    color: #a371f7;
  }

  .message {
    font-family: 'SFMono-Regular', Consolas, monospace;
    word-break: break-all;
    color: #c9d1d9;
  }

  /* Log syntax highlighting */
  :global(.log-uuid) {
    color: #a371f7;
    font-weight: 500;
  }

  :global(.log-id) {
    color: #79c0ff;
    font-weight: 500;
  }

  :global(.log-key) {
    color: #7ee787;
  }

  :global(.log-method) {
    color: #ff7b72;
    font-weight: 600;
  }

  :global(.log-path) {
    color: #a5d6ff;
  }

  :global(.log-ip) {
    color: #ffa657;
  }

  :global(.log-time) {
    color: #8b949e;
  }

  :global(.log-number) {
    color: #79c0ff;
  }

  :global(.log-string) {
    color: #a5d6ff;
  }

  :global(.log-status) {
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
  }

  :global(.log-status-2), :global(.log-status-200), :global(.log-status-201), :global(.log-status-204) {
    color: #3fb950;
    background: rgba(63, 185, 80, 0.15);
  }

  :global(.log-status-3), :global(.log-status-301), :global(.log-status-302), :global(.log-status-304) {
    color: #58a6ff;
    background: rgba(88, 166, 255, 0.15);
  }

  :global(.log-status-4), :global(.log-status-400), :global(.log-status-401), :global(.log-status-403), :global(.log-status-404) {
    color: #d29922;
    background: rgba(210, 153, 34, 0.15);
  }

  :global(.log-status-5), :global(.log-status-500), :global(.log-status-502), :global(.log-status-503) {
    color: #f85149;
    background: rgba(248, 81, 73, 0.15);
  }

  :global(.log-level-error), :global(.log-level-fatal), :global(.log-level-critical) {
    color: #f85149;
    font-weight: 600;
  }

  :global(.log-level-warn), :global(.log-level-warning) {
    color: #d29922;
    font-weight: 600;
  }

  :global(.log-level-info) {
    color: #3fb950;
  }

  :global(.log-level-debug), :global(.log-level-trace) {
    color: #8b949e;
  }

  .detail-row td {
    padding: 0;
    background: #0d1117;
  }

  /* Search highlight */
  :global(.search-highlight) {
    background: #f5a623;
    color: #0d1117;
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }
</style>
