<!--
  LogRow Component
  Single log row with column rendering

  Usage:
  <LogRow {log} {columns} {selected} {searchQuery} on:select />
-->
<script>
  import { createEventDispatcher } from 'svelte';
  import { formatTimestamp, formatFullTimestamp } from '../../utils/format.js';
  import { getLevelColor } from '../../utils/colors.js';
  import { highlightText } from '../../utils/dom.js';

  export let log;
  export let columns = [];
  export let selected = false;
  export let searchQuery = '';

  const dispatch = createEventDispatcher();

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

  function handleClick() {
    dispatch('select', { log });
  }

  $: levelColor = getLevelColor(log.level);
  $: highlightedMessage = highlightText(log.message, searchQuery);
</script>

<tr class="log-row" class:selected on:click={handleClick}>
  {#each columns as col (col.id)}
    <td style={col.width ? `width: ${col.width}px` : ''} class:pinned={col.pinned}>
      {#if col.id === 'time'}
        <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
          {formatTimestamp(log.timestamp)}
        </span>
      {:else if col.id === 'level'}
        <span class="level-badge" style="background: {levelColor}20; color: {levelColor}">
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
        <span class="message">{@html highlightedMessage}</span>
      {/if}
    </td>
  {/each}
</tr>

<style>
  .log-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .log-row:hover {
    background: var(--bg-row-hover, #1c2128);
  }

  .log-row.selected {
    background: var(--color-primary-bg, rgba(56, 139, 253, 0.08));
  }

  td {
    padding: 8px 12px;
    border-bottom: 1px solid var(--bg-tertiary, #21262d);
    vertical-align: top;
  }

  td.pinned {
    background: var(--bg-secondary, #161b22);
    position: sticky;
    left: 0;
    z-index: 1;
  }

  .log-row:hover td.pinned {
    background: var(--bg-row-hover, #1c2128);
  }

  .log-row.selected td.pinned {
    background: var(--color-primary-bg, rgba(56, 139, 253, 0.08));
  }

  .timestamp {
    font-family: var(--font-mono, 'SFMono-Regular', Consolas, monospace);
    color: var(--text-secondary, #8b949e);
    font-size: var(--text-sm, 12px);
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

  /* Search highlight */
  :global(.search-highlight) {
    background: var(--color-warning, #f5a623);
    color: var(--bg-primary, #0d1117);
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }
</style>
