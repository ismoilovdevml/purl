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
                      <button class="action-btn" on:click|stopPropagation={() => copyToClipboard(log.raw)} title="Copy raw log">
                        <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M4 2a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h5a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1H4Zm5 7H4V3h5v6Z"/><path fill="currentColor" d="M2 4v6a2 2 0 0 0 2 2h5v-1H4a1 1 0 0 1-1-1V4H2Z"/></svg>
                        Copy Raw
                      </button>
                      <button class="action-btn" on:click|stopPropagation={() => copyToClipboard(JSON.stringify(log, null, 2))} title="Copy as JSON">
                        <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M3 2a1 1 0 0 0-1 1v2a1 1 0 0 1-1 1 1 1 0 0 1 1 1v2a1 1 0 0 0 1 1M9 2a1 1 0 0 1 1 1v2a1 1 0 0 0 1 1 1 1 0 0 0-1 1v2a1 1 0 0 1-1 1"/></svg>
                        Copy JSON
                      </button>
                    </div>
                  </div>

                  <div class="detail-grid">
                    <div class="detail-field clickable" on:click|stopPropagation={() => copyToClipboard(log.timestamp)} title="Click to copy">
                      <span class="field-name">timestamp</span>
                      <span class="field-value mono">{log.timestamp}</span>
                    </div>
                    <div class="detail-field clickable" on:click|stopPropagation={() => copyToClipboard(log.level)} title="Click to copy">
                      <span class="field-name">level</span>
                      <span class="field-value">
                        <span class="level-badge-sm" style="background: {getLevelColor(log.level)}20; color: {getLevelColor(log.level)}">{log.level}</span>
                      </span>
                    </div>
                    <div class="detail-field clickable" on:click|stopPropagation={() => copyToClipboard(log.service)} title="Click to copy">
                      <span class="field-name">service</span>
                      <span class="field-value highlight-blue">{log.service}</span>
                    </div>
                    <div class="detail-field clickable" on:click|stopPropagation={() => copyToClipboard(log.host)} title="Click to copy">
                      <span class="field-name">host</span>
                      <span class="field-value highlight-purple">{log.host}</span>
                    </div>
                  </div>

                  <div class="detail-field full-width">
                    <span class="field-name">message</span>
                    <span class="field-value mono">{log.message}</span>
                  </div>

                  {#if log.meta && Object.keys(log.meta).length > 0}
                    <div class="detail-section">
                      <h5>
                        <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M2 3h8v1H2V3Zm0 2h8v1H2V5Zm0 2h6v1H2V7Zm0 2h4v1H2V9Z"/></svg>
                        Meta Fields
                      </h5>
                      <div class="meta-grid">
                        {#each Object.entries(log.meta) as [key, value]}
                          <div class="meta-field" on:click|stopPropagation={() => copyToClipboard(String(value))} title="Click to copy">
                            <span class="meta-key">{key}</span>
                            <span class="meta-value">
                              {typeof value === 'object' ? JSON.stringify(value) : value}
                            </span>
                          </div>
                        {/each}
                      </div>
                    </div>
                  {/if}

                  <div class="detail-section">
                    <h5>
                      <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M1 2h10a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H1a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1Zm0 1v6h10V3H1Zm1 1h2v1H2V4Zm3 0h5v1H5V4Zm-3 2h1v1H2V6Zm2 0h4v1H4V6Z"/></svg>
                      Raw Log
                    </h5>
                    <pre class="raw-log">{log.raw}</pre>
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
    padding: 16px 20px;
    border-top: 2px solid #30363d;
  }

  .detail-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
    padding-bottom: 12px;
    border-bottom: 1px solid #21262d;
  }

  .detail-header h4 {
    font-size: 14px;
    font-weight: 600;
    color: #c9d1d9;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .detail-actions {
    display: flex;
    gap: 8px;
  }

  .action-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 12px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .action-btn:hover {
    background: #30363d;
    border-color: #484f58;
  }

  .action-btn svg {
    color: #8b949e;
  }

  .detail-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 12px;
    margin-bottom: 16px;
  }

  .detail-field {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 10px 12px;
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 6px;
  }

  .detail-field.clickable {
    cursor: pointer;
    transition: all 0.15s;
  }

  .detail-field.clickable:hover {
    border-color: #30363d;
    background: #1c2128;
  }

  .detail-field.full-width {
    grid-column: 1 / -1;
    margin-bottom: 8px;
  }

  .field-name {
    font-size: 11px;
    font-weight: 500;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .field-value {
    color: #c9d1d9;
    font-size: 13px;
    word-break: break-all;
  }

  .field-value.mono {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
  }

  .field-value.highlight-blue {
    color: #58a6ff;
    font-weight: 500;
  }

  .field-value.highlight-purple {
    color: #a371f7;
    font-weight: 500;
  }

  .level-badge-sm {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .detail-section {
    margin-top: 16px;
  }

  .detail-section h5 {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 11px;
    font-weight: 600;
    color: #8b949e;
    margin-bottom: 10px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .detail-section h5 svg {
    color: #6e7681;
  }

  .meta-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 8px;
  }

  .meta-field {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 8px 10px;
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 4px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .meta-field:hover {
    border-color: #30363d;
    background: #1c2128;
  }

  .meta-key {
    font-size: 10px;
    color: #6e7681;
    text-transform: uppercase;
  }

  .meta-value {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
    color: #c9d1d9;
    word-break: break-all;
  }

  .raw-log {
    padding: 14px;
    background: #161b22;
    border: 1px solid #21262d;
    border-radius: 6px;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
    color: #c9d1d9;
    white-space: pre-wrap;
    word-break: break-all;
    margin: 0;
    line-height: 1.6;
  }
</style>
