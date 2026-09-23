<!--
  TraceLogsTable
  The log lines of a looked-up trace/request. A row click expands the raw
  JSON of that line beneath it; one row is open at a time.
-->
<script>
  import Badge from '../ui/Badge.svelte';
  import { formatTimestamp, formatFullTimestamp } from '../../utils/format.js';
  import { getLevelVariant } from '../../utils/colors.js';

  /**
   * @type {{
   *   logs: Array<Record<string, any>>,
   *   serviceColor: (service: string) => string,
   * }}
   */
  let { logs, serviceColor } = $props();

  // Local on purpose: the parent unmounts this table while a new lookup is
  // loading, so a new result set always starts with every row collapsed.
  let expandedLogIndex = $state(-1);

  function toggleLogExpand(index) {
    expandedLogIndex = expandedLogIndex === index ? -1 : index;
  }

  function levelOf(log) {
    return (log.level || '').toLowerCase();
  }
</script>

<div class="logs-section">
  <div class="section-header">
    <h2>Logs</h2>
    <span class="section-meta">{logs.length} entries</span>
  </div>
  <div class="logs-table-wrapper">
    <table class="logs-table">
      <thead>
        <tr>
          <th class="col-timestamp">Timestamp</th>
          <th class="col-service">Service</th>
          <th class="col-level">Level</th>
          <th class="col-message">Message</th>
        </tr>
      </thead>
      <tbody>
        {#each logs as log, i (i)}
          <tr
            class="log-row"
            class:log-error={levelOf(log) === 'error' || levelOf(log) === 'fatal'}
            class:log-warn={levelOf(log) === 'warn' || levelOf(log) === 'warning'}
            class:expanded={expandedLogIndex === i}
            onclick={() => toggleLogExpand(i)}
          >
            <td class="col-timestamp">
              <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
                {formatTimestamp(log.timestamp)}
              </span>
            </td>
            <td class="col-service">
              {#if log.service}
                <span class="service-tag" style="border-color: {serviceColor(log.service)}; color: {serviceColor(log.service)}">
                  {log.service}
                </span>
              {:else}
                <span class="muted">-</span>
              {/if}
            </td>
            <td class="col-level">
              <Badge variant={getLevelVariant(log.level)} size="sm">
                {(log.level || 'unknown').toUpperCase()}
              </Badge>
            </td>
            <td class="col-message">
              <span class="message-text">{log.message || log.msg || '-'}</span>
            </td>
          </tr>
          {#if expandedLogIndex === i}
            <tr class="log-detail-row">
              <td colspan="4">
                <div class="log-detail">
                  <pre class="log-json">{JSON.stringify(log, null, 2)}</pre>
                </div>
              </td>
            </tr>
          {/if}
        {/each}
      </tbody>
    </table>
  </div>
</div>

<style>
  .logs-section {
    flex: 1;
  }

  .section-header {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
  }

  h2 {
    font-size: 0.75rem;
    font-weight: 600;
    color: #8b949e;
    margin: 0;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .section-meta {
    font-size: 0.6875rem;
    color: #848d97;
  }

  .logs-table-wrapper {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
  }

  .logs-table {
    width: 100%;
    border-collapse: collapse;
    table-layout: fixed;
  }

  .logs-table thead {
    position: sticky;
    top: 0;
    z-index: 1;
  }

  .logs-table th {
    background: #1c2128;
    padding: 8px 12px;
    text-align: left;
    font-size: 0.6875rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    border-bottom: 1px solid #30363d;
  }

  .logs-table td {
    padding: 6px 12px;
    font-size: 0.8125rem;
    color: #c9d1d9;
    border-bottom: 1px solid #21262d;
    vertical-align: middle;
  }

  .col-timestamp {
    width: 110px;
  }

  .col-service {
    width: 120px;
  }

  .col-level {
    width: 80px;
  }

  .log-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .log-row:hover {
    background: rgba(88, 166, 255, 0.04);
  }

  .log-row.expanded {
    background: rgba(88, 166, 255, 0.06);
  }

  .log-row.log-error {
    background: rgba(248, 81, 73, 0.04);
  }

  .log-row.log-error:hover {
    background: rgba(248, 81, 73, 0.08);
  }

  .log-row.log-warn {
    background: rgba(210, 153, 34, 0.03);
  }

  .log-row.log-warn:hover {
    background: rgba(210, 153, 34, 0.06);
  }

  .timestamp {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #8b949e;
  }

  .service-tag {
    display: inline-block;
    padding: 1px 6px;
    font-size: 0.6875rem;
    font-weight: 500;
    border: 1px solid;
    border-radius: 4px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 100%;
  }

  .muted {
    color: #848d97;
  }

  .message-text {
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }

  /* Expanded log detail */
  .log-detail-row td {
    padding: 0;
    background: #0d1117;
  }

  .log-detail {
    padding: 12px 16px;
  }

  .log-json {
    margin: 0;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #c9d1d9;
    line-height: 1.5;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 300px;
    overflow-y: auto;
    background: #0d1117;
    border-radius: 4px;
  }

  @media (max-width: 900px) {
    .col-timestamp {
      width: 90px;
    }

    .col-service {
      width: 90px;
    }
  }
</style>
