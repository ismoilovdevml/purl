<script>
  import { onMount } from 'svelte';
  import { formatTimestamp, formatFullTimestamp, getLevelColor } from '../stores/logs.js';

  export let logs = [];

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
      } catch (e) {}
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
                <div class="resize-handle" role="separator" aria-orientation="vertical" on:mousedown={(e) => startResize(e, col.id)}></div>
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
                <span class="message">{log.message}</span>
              </td>
            {/if}
          </tr>

          {#if selectedLog?.id === log.id}
            <tr class="detail-row">
              <td colspan={colspanCount}>
                <div class="log-detail">
                  <div class="detail-header">
                    <h4>Log Details</h4>
                    <div class="detail-actions">
                      <button on:click={() => copyToClipboard(log.raw)}>Copy Raw</button>
                      <button on:click={() => copyToClipboard(JSON.stringify(log, null, 2))}>Copy JSON</button>
                    </div>
                  </div>

                  <div class="detail-fields">
                    <div class="detail-field">
                      <span class="field-name">timestamp</span>
                      <span class="field-value">{log.timestamp}</span>
                    </div>
                    <div class="detail-field">
                      <span class="field-name">level</span>
                      <span class="field-value">{log.level}</span>
                    </div>
                    <div class="detail-field">
                      <span class="field-name">service</span>
                      <span class="field-value">{log.service}</span>
                    </div>
                    <div class="detail-field">
                      <span class="field-name">host</span>
                      <span class="field-value">{log.host}</span>
                    </div>
                    <div class="detail-field">
                      <span class="field-name">message</span>
                      <span class="field-value">{log.message}</span>
                    </div>

                    {#if log.meta && Object.keys(log.meta).length > 0}
                      <div class="detail-section">
                        <h5>Meta Fields</h5>
                        {#each Object.entries(log.meta) as [key, value]}
                          <div class="detail-field">
                            <span class="field-name">{key}</span>
                            <span class="field-value">
                              {typeof value === 'object' ? JSON.stringify(value) : value}
                            </span>
                          </div>
                        {/each}
                      </div>
                    {/if}

                    <div class="detail-section">
                      <h5>Raw Log</h5>
                      <pre class="raw-log">{log.raw}</pre>
                    </div>
                  </div>
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
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 100;
    min-width: 180px;
    overflow: hidden;
  }

  .column-menu-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px 12px;
    border-bottom: 1px solid #30363d;
    font-size: 12px;
    color: #8b949e;
  }

  .reset-btn {
    background: none;
    border: none;
    color: #58a6ff;
    cursor: pointer;
    font-size: 11px;
  }

  .reset-btn:hover {
    text-decoration: underline;
  }

  .column-option {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    cursor: pointer;
    font-size: 13px;
    color: #c9d1d9;
  }

  .column-option:hover {
    background: #21262d;
  }

  .column-option input {
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

  .detail-row td {
    padding: 0;
    background: #0d1117;
  }

  .log-detail {
    padding: 16px;
    border-top: 1px solid #30363d;
  }

  .detail-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
  }

  .detail-header h4 {
    font-size: 14px;
    font-weight: 600;
    color: #c9d1d9;
  }

  .detail-actions {
    display: flex;
    gap: 8px;
  }

  .detail-actions button {
    padding: 4px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #c9d1d9;
    font-size: 12px;
    cursor: pointer;
  }

  .detail-actions button:hover {
    background: #30363d;
  }

  .detail-fields {
    display: grid;
    gap: 8px;
  }

  .detail-field {
    display: flex;
    gap: 16px;
    padding: 6px 0;
    border-bottom: 1px solid #21262d;
  }

  .field-name {
    width: 120px;
    flex-shrink: 0;
    color: #58a6ff;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
  }

  .field-value {
    flex: 1;
    color: #c9d1d9;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
    word-break: break-all;
  }

  .detail-section {
    margin-top: 16px;
  }

  .detail-section h5 {
    font-size: 12px;
    font-weight: 600;
    color: #8b949e;
    margin-bottom: 8px;
    text-transform: uppercase;
  }

  .raw-log {
    padding: 12px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 4px;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
    color: #c9d1d9;
    white-space: pre-wrap;
    word-break: break-all;
    margin: 0;
  }
</style>
