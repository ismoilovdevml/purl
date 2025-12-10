<script>
  import { formatTimestamp, formatFullTimestamp, getLevelColor } from '../stores/logs.js';

  export let logs = [];

  let selectedLog = null;

  function selectLog(log) {
    selectedLog = selectedLog?.id === log.id ? null : log;
  }

  function copyToClipboard(text) {
    navigator.clipboard.writeText(text);
  }
</script>

<div class="log-table-container">
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
    <table class="log-table">
      <thead>
        <tr>
          <th class="col-time">Time</th>
          <th class="col-level">Level</th>
          <th class="col-service">Service</th>
          <th class="col-message">Message</th>
        </tr>
      </thead>
      <tbody>
        {#each logs as log, i (log.id || i)}
          <tr
            class="log-row"
            class:selected={selectedLog?.id === log.id}
            on:click={() => selectLog(log)}
          >
            <td class="col-time">
              <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
                {formatTimestamp(log.timestamp)}
              </span>
            </td>
            <td class="col-level">
              <span class="level-badge" style="background: {getLevelColor(log.level)}20; color: {getLevelColor(log.level)}">
                {log.level}
              </span>
            </td>
            <td class="col-service">
              <span class="service">{log.service}</span>
            </td>
            <td class="col-message">
              <span class="message">{log.message}</span>
            </td>
          </tr>

          {#if selectedLog?.id === log.id}
            <tr class="detail-row">
              <td colspan="4">
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
  }

  .col-time { width: 90px; }
  .col-level { width: 100px; }
  .col-service { width: 150px; }
  .col-message { width: auto; }

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
