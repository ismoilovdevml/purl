<!--
  LogCell
  The content of one data cell in the log table, for one column of one log.
  The surrounding <td> (width, pinning) stays in LogTable.
-->
<script>
  import { formatTimestamp, formatFullTimestamp } from '../../utils/format.js';
  import { getLevelColor, getLevelBgColor } from '../../utils/colors.js';
  import { highlightText } from '../../utils/dom.js';

  let {
    log,
    /** Column id: time | level | service | host | namespace | pod | node | message */
    column,
    /** Timestamp display format from settings */
    timeFormat,
    /** Current search query, highlighted inside the message */
    searchQuery = '',
  } = $props();

  // Use the meta pre-parsed by stores/logs.js when available.
  function getMetaField(entry, field) {
    if (entry.parsedMeta) {
      return entry.parsedMeta[field] || '';
    }
    if (!entry.meta) return '';
    try {
      const meta = typeof entry.meta === 'string' ? JSON.parse(entry.meta) : entry.meta;
      return meta[field] || '';
    } catch {
      return '';
    }
  }
</script>

{#if column === 'time'}
  <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
    {formatTimestamp(log.timestamp, timeFormat)}
  </span>
{:else if column === 'level'}
  <span class="level-badge" style="background: {getLevelBgColor(log.level)}; color: {getLevelColor(log.level)}">
    {log.level}
  </span>
{:else if column === 'service'}
  <span class="service">{log.service}</span>
{:else if column === 'host'}
  <span class="host">{log.host}</span>
{:else if column === 'namespace'}
  <span class="namespace">{getMetaField(log, 'namespace')}</span>
{:else if column === 'pod'}
  <span class="pod">{getMetaField(log, 'pod')}</span>
{:else if column === 'node'}
  <span class="node">{getMetaField(log, 'node')}</span>
{:else if column === 'message'}
  <!-- highlightText() HTML-escapes the log line before adding <mark> tags. -->
  <!-- eslint-disable-next-line svelte/no-at-html-tags -->
  <span class="message">{@html highlightText(log.message, searchQuery)}</span>
{/if}

<style>
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

  /* Table-level display modes are classes on LogTable's <table>. */
  :global(.log-table.compact) .level-badge {
    padding: 1px 6px;
    font-size: 10px;
  }

  :global(.log-table.no-wrap) .message {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 600px;
  }
</style>
