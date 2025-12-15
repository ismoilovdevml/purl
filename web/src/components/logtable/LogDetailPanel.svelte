<script>
  import { getLevelColor, filterByTrace, filterByRequest } from '../../stores/logs.js';
  import { highlightText } from '../../lib/utils.js';
  import ContextPanel from './ContextPanel.svelte';

  export let log;
  export let searchQuery = '';
  export let contextData = null;
  export let contextLoading = false;
  export let onLoadContext;
  export let onCloseContext;

  // Copy feedback state
  let copiedField = null;
  let copiedTimeout = null;

  function copyToClipboard(text, fieldId = null) {
    navigator.clipboard.writeText(text);

    if (copiedTimeout) clearTimeout(copiedTimeout);
    copiedField = fieldId || text;
    copiedTimeout = setTimeout(() => {
      copiedField = null;
    }, 700);
  }
</script>

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
      class:active={contextData}
      on:click|stopPropagation={onLoadContext}
      title="Show surrounding logs"
      disabled={contextLoading}
    >
      {#if contextLoading}
        Loading...
      {:else if contextData}
        Hide Context
      {:else}
        Show Context
      {/if}
    </button>
  </div>

  <div class="detail-lines">
    <button type="button" class="detail-line" class:copied={copiedField === `${log.id}-timestamp`} on:click|stopPropagation={() => copyToClipboard(log.timestamp, `${log.id}-timestamp`)}>
      <span class="line-key">timestamp</span>
      <span class="line-value mono">{log.timestamp}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-timestamp` ? 'Copied!' : ''}</span>
    </button>
    <button type="button" class="detail-line" class:copied={copiedField === `${log.id}-level`} on:click|stopPropagation={() => copyToClipboard(log.level, `${log.id}-level`)}>
      <span class="line-key">level</span>
      <span class="line-value" style="color: {getLevelColor(log.level)}">{log.level}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-level` ? 'Copied!' : ''}</span>
    </button>
    <button type="button" class="detail-line" class:copied={copiedField === `${log.id}-service`} on:click|stopPropagation={() => copyToClipboard(log.service, `${log.id}-service`)}>
      <span class="line-key">service</span>
      <span class="line-value blue">{log.service}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-service` ? 'Copied!' : ''}</span>
    </button>
    <button type="button" class="detail-line" class:copied={copiedField === `${log.id}-host`} on:click|stopPropagation={() => copyToClipboard(log.host, `${log.id}-host`)}>
      <span class="line-key">host</span>
      <span class="line-value purple">{log.host}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-host` ? 'Copied!' : ''}</span>
    </button>
    <button type="button" class="detail-line msg" class:copied={copiedField === `${log.id}-message`} on:click|stopPropagation={() => copyToClipboard(log.message, `${log.id}-message`)}>
      <span class="line-key">message</span>
      <!-- eslint-disable-next-line svelte/no-at-html-tags -->
      <span class="line-value mono">{@html highlightText(log.message, searchQuery)}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-message` ? 'Copied!' : ''}</span>
    </button>

    {#if log.meta}
      {@const parsedMeta = typeof log.meta === 'string' ? (() => { try { return JSON.parse(log.meta); } catch { return null; } })() : log.meta}
      {#if parsedMeta && typeof parsedMeta === 'object' && Object.keys(parsedMeta).length > 0}
        {#each Object.entries(parsedMeta) as [key, value]}
          <button type="button" class="detail-line meta" class:copied={copiedField === `${log.id}-${key}`} on:click|stopPropagation={() => copyToClipboard(String(value), `${log.id}-${key}`)}>
            <span class="line-key">{key}</span>
            <span class="line-value mono">{typeof value === 'object' ? JSON.stringify(value) : value}</span>
            <span class="copy-feedback">{copiedField === `${log.id}-${key}` ? 'Copied!' : ''}</span>
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

  {#if contextData}
    <ContextPanel {contextData} {log} onClose={onCloseContext} />
  {/if}
</div>

<style>
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

  .detail-line.copied {
    background: rgba(35, 134, 54, 0.2) !important;
    border-left: 3px solid #3fb950;
  }

  .copy-feedback {
    flex-shrink: 0;
    font-size: 11px;
    color: #3fb950;
    font-weight: 600;
    margin-left: auto;
    padding: 2px 8px;
    opacity: 0;
    transition: opacity 0.1s;
  }

  .detail-line.copied .copy-feedback {
    opacity: 1;
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

  /* Search highlight */
  :global(.search-highlight) {
    background: #f5a623;
    color: #0d1117;
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }
</style>
