<script>
  import { onMount } from 'svelte';
  import { formatTimestamp, formatFullTimestamp, getLevelColor, query, fetchLogContext, filterByTrace, filterByRequest } from '../stores/logs.js';

  export let logs = [];

  // Context state
  let contextData = {};
  let contextLoading = {};

  // Current search query for highlighting
  let searchQuery = '';
  query.subscribe(v => searchQuery = v);

  // Escape HTML to prevent XSS
  function escapeHtml(text) {
    if (!text) return '';
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  // Highlight matching text in a string (XSS-safe)
  function highlightText(text, query) {
    if (!text) return '';
    // First escape HTML in the text
    let safeText = escapeHtml(text);

    // Then highlight search query if present
    if (query) {
      const safeQuery = escapeHtml(query);
      const escaped = safeQuery.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const regex = new RegExp(`(${escaped})`, 'gi');
      safeText = safeText.replace(regex, '<mark class="search-highlight">$1</mark>');
    }

    return safeText;
  }

  let selectedLog = null;
  let showColumnMenu = false;

  // Column configuration with resizable widths
  let columns = [
    { id: 'time', label: 'Time', visible: true, width: 90, minWidth: 60 },
    { id: 'level', label: 'Level', visible: true, width: 100, minWidth: 60 },
    { id: 'service', label: 'Service', visible: true, width: 150, minWidth: 80 },
    { id: 'host', label: 'Host', visible: false, width: 120, minWidth: 80 },
    { id: 'message', label: 'Message', visible: true, width: null, minWidth: 200 }
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
      columns.map(c => ({ id: c.id, visible: c.visible, width: c.width }))
    ));
  }

  function selectLog(log) {
    selectedLog = selectedLog?.id === log.id ? null : log;
  }

  function copyToClipboard(text) {
    navigator.clipboard.writeText(text);
  }

  async function loadContext(logId) {
    if (contextData[logId]) {
      // Toggle off if already loaded
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

  function toggleColumn(colId) {
    const col = columns.find(c => c.id === colId);
    if (col) {
      col.visible = !col.visible;
      columns = columns;
      saveColumnConfig();
    }
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

  function resetColumns() {
    columns = [
      { id: 'time', label: 'Time', visible: true, width: 90, minWidth: 60 },
      { id: 'level', label: 'Level', visible: true, width: 100, minWidth: 60 },
      { id: 'service', label: 'Service', visible: true, width: 150, minWidth: 80 },
      { id: 'host', label: 'Host', visible: false, width: 120, minWidth: 80 },
      { id: 'message', label: 'Message', visible: true, width: null, minWidth: 200 }
    ];
    saveColumnConfig();
  }

  $: visibleColumns = columns.filter(c => c.visible);
  $: colspanCount = visibleColumns.length;
</script>

<div class="log-table-container">
  <!-- Column Settings Menu -->
  <div class="table-toolbar">
    <div class="column-menu-container">
      <button class="toolbar-btn" on:click={() => showColumnMenu = !showColumnMenu} title="Configure columns">
        <svg width="14" height="14" viewBox="0 0 14 14">
          <path fill="currentColor" d="M1 2h12v2H1V2Zm0 4h12v2H1V6Zm0 4h8v2H1v-2Z"/>
        </svg>
        Columns
      </button>
      {#if showColumnMenu}
        <div class="column-menu">
          <div class="column-menu-header">
            <span>Show/Hide Columns</span>
            <button class="reset-btn" on:click={resetColumns}>Reset</button>
          </div>
          {#each columns as col}
            <label class="column-option">
              <input type="checkbox" checked={col.visible} on:change={() => toggleColumn(col.id)} />
              <span>{col.label}</span>
            </label>
          {/each}
        </div>
      {/if}
    </div>
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
                <div class="log-detail">
                  <div class="detail-actions">
                    <button class="copy-btn" on:click|stopPropagation={() => copyToClipboard(log.raw || log.message)} title="Copy raw log">
                      Copy
                    </button>
                    <button class="copy-btn" on:click|stopPropagation={() => copyToClipboard(JSON.stringify(log, null, 2))} title="Copy as JSON">
                      JSON
                    </button>
                    <button
                      class="context-btn"
                      class:active={contextData[log.id]}
                      on:click|stopPropagation={() => loadContext(log.id)}
                      title="Show surrounding logs"
                      disabled={contextLoading[log.id]}
                    >
                      {#if contextLoading[log.id]}
                        Loading...
                      {:else if contextData[log.id]}
                        Hide Context
                      {:else}
                        Show Context
                      {/if}
                    </button>
                  </div>

                  <div class="detail-lines">
                    <button type="button" class="detail-line" on:click|stopPropagation={() => copyToClipboard(log.timestamp)}>
                      <span class="line-key">timestamp</span>
                      <span class="line-value mono">{log.timestamp}</span>
                    </button>
                    <button type="button" class="detail-line" on:click|stopPropagation={() => copyToClipboard(log.level)}>
                      <span class="line-key">level</span>
                      <span class="line-value" style="color: {getLevelColor(log.level)}">{log.level}</span>
                    </button>
                    <button type="button" class="detail-line" on:click|stopPropagation={() => copyToClipboard(log.service)}>
                      <span class="line-key">service</span>
                      <span class="line-value blue">{log.service}</span>
                    </button>
                    <button type="button" class="detail-line" on:click|stopPropagation={() => copyToClipboard(log.host)}>
                      <span class="line-key">host</span>
                      <span class="line-value purple">{log.host}</span>
                    </button>
                    <button type="button" class="detail-line msg" on:click|stopPropagation={() => copyToClipboard(log.message)}>
                      <span class="line-key">message</span>
                      <!-- eslint-disable-next-line svelte/no-at-html-tags -->
                      <span class="line-value mono">{@html highlightText(log.message, searchQuery)}</span>
                    </button>

                    {#if log.meta}
                      {@const parsedMeta = typeof log.meta === 'string' ? (() => { try { return JSON.parse(log.meta); } catch { return null; } })() : log.meta}
                      {#if parsedMeta && typeof parsedMeta === 'object' && Object.keys(parsedMeta).length > 0}
                        {#each Object.entries(parsedMeta) as [key, value]}
                          <button type="button" class="detail-line meta" on:click|stopPropagation={() => copyToClipboard(String(value))}>
                            <span class="line-key">{key}</span>
                            <span class="line-value mono">{typeof value === 'object' ? JSON.stringify(value) : value}</span>
                          </button>
                        {/each}
                      {/if}
                    {/if}

                    {#if log.trace_id}
                      <button type="button" class="detail-line trace" on:click|stopPropagation={() => filterByTrace(log.trace_id)} title="Filter by trace ID">
                        <span class="line-key">trace_id</span>
                        <span class="line-value mono trace-link">{log.trace_id}</span>
                        <span class="trace-action">Filter</span>
                      </button>
                    {/if}

                    {#if log.request_id}
                      <button type="button" class="detail-line trace" on:click|stopPropagation={() => filterByRequest(log.request_id)} title="Filter by request ID">
                        <span class="line-key">request_id</span>
                        <span class="line-value mono trace-link">{log.request_id}</span>
                        <span class="trace-action">Filter</span>
                      </button>
                    {/if}

                    {#if log.span_id}
                      <button type="button" class="detail-line" on:click|stopPropagation={() => copyToClipboard(log.span_id)}>
                        <span class="line-key">span_id</span>
                        <span class="line-value mono">{log.span_id}</span>
                      </button>
                    {/if}

                    {#if log.parent_span_id}
                      <button type="button" class="detail-line" on:click|stopPropagation={() => copyToClipboard(log.parent_span_id)}>
                        <span class="line-key">parent_span</span>
                        <span class="line-value mono">{log.parent_span_id}</span>
                      </button>
                    {/if}

                    {#if log.raw && log.raw !== log.message}
                      <div class="detail-line raw">
                        <span class="line-key">raw</span>
                        <pre class="line-value mono">{log.raw}</pre>
                      </div>
                    {/if}
                  </div>

                  <!-- Context Panel -->
                  {#if contextData[log.id]}
                    <div class="context-panel">
                      <div class="context-header">
                        <span class="context-title">
                          Context: {contextData[log.id].before_count} before, {contextData[log.id].after_count} after
                        </span>
                        <button class="context-close" on:click|stopPropagation={() => closeContext(log.id)}>
                          Close
                        </button>
                      </div>
                      <div class="context-logs">
                        <!-- Before logs -->
                        {#each contextData[log.id].before_logs as ctxLog}
                          <div class="context-log before">
                            <span class="ctx-time">{formatTimestamp(ctxLog.timestamp)}</span>
                            <span class="ctx-level" style="color: {getLevelColor(ctxLog.level)}">{ctxLog.level}</span>
                            <span class="ctx-message">{ctxLog.message}</span>
                          </div>
                        {/each}

                        <!-- Current log marker -->
                        <div class="context-log current">
                          <span class="ctx-time">{formatTimestamp(log.timestamp)}</span>
                          <span class="ctx-level" style="color: {getLevelColor(log.level)}">{log.level}</span>
                          <span class="ctx-message">{log.message}</span>
                          <span class="ctx-marker">← Current</span>
                        </div>

                        <!-- After logs -->
                        {#each contextData[log.id].after_logs as ctxLog}
                          <div class="context-log after">
                            <span class="ctx-time">{formatTimestamp(ctxLog.timestamp)}</span>
                            <span class="ctx-level" style="color: {getLevelColor(ctxLog.level)}">{ctxLog.level}</span>
                            <span class="ctx-message">{ctxLog.message}</span>
                          </div>
                        {/each}
                      </div>
                    </div>
                  {/if}
                </div>
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

  .table-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: #21262d;
    border-bottom: 1px solid #30363d;
  }

  .column-menu-container {
    position: relative;
  }

  .toolbar-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #c9d1d9;
    font-size: 12px;
    cursor: pointer;
  }

  .toolbar-btn:hover {
    background: #30363d;
  }

  .toolbar-info {
    font-size: 12px;
    color: #8b949e;
  }

  .column-menu {
    position: absolute;
    top: 100%;
    left: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
    z-index: 100;
    min-width: 240px;
    overflow: hidden;
  }

  .column-menu-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid #30363d;
    font-size: 13px;
    font-weight: 500;
    color: #c9d1d9;
  }

  .reset-btn {
    background: none;
    border: none;
    color: #58a6ff;
    cursor: pointer;
    font-size: 12px;
    padding: 4px 8px;
    border-radius: 4px;
  }

  .reset-btn:hover {
    background: #21262d;
  }

  .column-option {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 16px;
    cursor: pointer;
    font-size: 14px;
    color: #c9d1d9;
    transition: background 0.1s;
  }

  .column-option:hover {
    background: #21262d;
  }

  .column-option input {
    width: 16px;
    height: 16px;
    accent-color: #58a6ff;
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 60px 20px;
    color: #8b949e;
  }

  .empty-state svg {
    margin-bottom: 16px;
    color: #30363d;
  }

  .empty-state p {
    font-size: 16px;
    font-weight: 500;
    margin-bottom: 4px;
  }

  .empty-state span {
    font-size: 14px;
    color: #6e7681;
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

  .log-detail {
    padding: 12px 16px;
    border-left: 3px solid #30363d;
    margin-left: 8px;
    max-width: 100%;
    overflow: hidden;
  }

  .detail-actions {
    display: flex;
    gap: 6px;
    margin-bottom: 10px;
  }

  .copy-btn {
    padding: 4px 10px;
    background: transparent;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #8b949e;
    font-size: 11px;
    cursor: pointer;
  }

  .copy-btn:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .detail-lines {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .detail-line {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 4px 8px;
    border-radius: 4px;
    cursor: pointer;
    width: 100%;
    text-align: left;
    background: transparent;
    border: none;
  }

  .detail-line:hover {
    background: #161b22;
  }

  .detail-line.msg {
    margin-top: 6px;
    padding-top: 8px;
    border-top: 1px solid #21262d;
  }

  .detail-line.meta {
    opacity: 0.85;
  }

  .detail-line.raw {
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid #21262d;
    flex-direction: column;
    gap: 4px;
  }

  .line-key {
    min-width: 80px;
    font-size: 12px;
    color: #6e7681;
  }

  .line-value {
    flex: 1;
    font-size: 13px;
    color: #c9d1d9;
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }

  .line-value.mono {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
  }

  .line-value.blue {
    color: #58a6ff;
  }

  .line-value.purple {
    color: #a371f7;
  }

  .detail-line.raw .line-value {
    white-space: pre-wrap;
    background: #161b22;
    padding: 8px;
    border-radius: 4px;
    margin: 0;
  }

  /* Search highlight */
  :global(.search-highlight) {
    background: #f5a623;
    color: #0d1117;
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }

  /* Context button */
  .context-btn {
    padding: 4px 10px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #58a6ff;
    font-size: 11px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .context-btn:hover {
    background: #30363d;
    border-color: #58a6ff;
  }

  .context-btn.active {
    background: #388bfd20;
    border-color: #58a6ff;
  }

  .context-btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  /* Context panel */
  .context-panel {
    margin-top: 12px;
    border: 1px solid #30363d;
    border-radius: 6px;
    background: #0d1117;
    overflow: hidden;
  }

  .context-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    background: #161b22;
    border-bottom: 1px solid #30363d;
  }

  .context-title {
    font-size: 12px;
    color: #8b949e;
    font-weight: 500;
  }

  .context-close {
    padding: 2px 8px;
    background: transparent;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #8b949e;
    font-size: 11px;
    cursor: pointer;
  }

  .context-close:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .context-logs {
    max-height: 400px;
    overflow-y: auto;
  }

  .context-log {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 6px 12px;
    font-size: 12px;
    border-bottom: 1px solid #21262d;
  }

  .context-log:last-child {
    border-bottom: none;
  }

  .context-log.before {
    background: #161b2280;
    opacity: 0.7;
  }

  .context-log.after {
    background: #161b2280;
    opacity: 0.7;
  }

  .context-log.current {
    background: #388bfd15;
    border-left: 3px solid #58a6ff;
    font-weight: 500;
  }

  .ctx-time {
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #8b949e;
    flex-shrink: 0;
    width: 70px;
  }

  .ctx-level {
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
    width: 60px;
  }

  .ctx-message {
    flex: 1;
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #c9d1d9;
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .ctx-marker {
    color: #58a6ff;
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
  }

  /* Trace/Request ID styling */
  .detail-line.trace {
    background: #21262d;
    border: 1px solid #30363d;
    margin-top: 4px;
    border-radius: 4px;
  }

  .detail-line.trace:hover {
    background: #30363d;
    border-color: #58a6ff;
  }

  .trace-link {
    color: #58a6ff;
  }

  .trace-action {
    font-size: 11px;
    color: #8b949e;
    background: #21262d;
    padding: 2px 6px;
    border-radius: 3px;
    flex-shrink: 0;
  }

  .detail-line.trace:hover .trace-action {
    background: #388bfd30;
    color: #58a6ff;
  }
</style>
