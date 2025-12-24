<!--
  LogDetail Component
  Expanded log details panel with copy functionality

  Usage:
  <LogDetail {log} {searchQuery} on:filterTrace on:filterRequest on:showContext />
-->
<script>
  import { createEventDispatcher } from 'svelte';
  import { getLevelColor } from '../../utils/colors.js';
  import { highlightText, copyToClipboard } from '../../utils/dom.js';

  export let log;
  export let searchQuery = '';
  export let showContextButton = true;
  export let contextLoading = false;
  export let contextOpen = false;

  const dispatch = createEventDispatcher();

  // Copy feedback state
  let copiedField = null;
  let copiedTimeout = null;

  function handleCopy(text, fieldId = null) {
    copyToClipboard(text);

    if (copiedTimeout) clearTimeout(copiedTimeout);
    copiedField = fieldId || text;
    copiedTimeout = setTimeout(() => {
      copiedField = null;
    }, 700);
  }

  function handleFilterTrace() {
    dispatch('filterTrace', { traceId: log.trace_id });
  }

  function handleFilterRequest() {
    dispatch('filterRequest', { requestId: log.request_id });
  }

  function handleShowContext() {
    dispatch('showContext', { logId: log.id });
  }

  $: levelColor = getLevelColor(log.level);
  $: highlightedMessage = highlightText(log.message, searchQuery);
  $: parsedMeta = (() => {
    if (!log.meta) return null;
    try {
      return typeof log.meta === 'string' ? JSON.parse(log.meta) : log.meta;
    } catch {
      return null;
    }
  })();
</script>

<div class="log-detail">
  <div class="detail-actions">
    <button class="action-btn" on:click|stopPropagation={() => handleCopy(log.raw || log.message)} title="Copy raw log">
      Copy
    </button>
    <button class="action-btn" on:click|stopPropagation={() => handleCopy(JSON.stringify(log, null, 2))} title="Copy as JSON">
      JSON
    </button>
    {#if showContextButton}
      <button
        class="action-btn context"
        class:active={contextOpen}
        on:click|stopPropagation={handleShowContext}
        title="Show surrounding logs"
        disabled={contextLoading}
      >
        {#if contextLoading}
          Loading...
        {:else if contextOpen}
          Hide Context
        {:else}
          Show Context
        {/if}
      </button>
    {/if}
  </div>

  <div class="detail-lines">
    <!-- Timestamp -->
    <button
      type="button"
      class="detail-line"
      class:copied={copiedField === `${log.id}-timestamp`}
      on:click|stopPropagation={() => handleCopy(log.timestamp, `${log.id}-timestamp`)}
    >
      <span class="line-key">timestamp</span>
      <span class="line-value mono">{log.timestamp}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-timestamp` ? 'Copied!' : ''}</span>
    </button>

    <!-- Level -->
    <button
      type="button"
      class="detail-line"
      class:copied={copiedField === `${log.id}-level`}
      on:click|stopPropagation={() => handleCopy(log.level, `${log.id}-level`)}
    >
      <span class="line-key">level</span>
      <span class="line-value" style="color: {levelColor}">{log.level}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-level` ? 'Copied!' : ''}</span>
    </button>

    <!-- Service -->
    <button
      type="button"
      class="detail-line"
      class:copied={copiedField === `${log.id}-service`}
      on:click|stopPropagation={() => handleCopy(log.service, `${log.id}-service`)}
    >
      <span class="line-key">service</span>
      <span class="line-value blue">{log.service}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-service` ? 'Copied!' : ''}</span>
    </button>

    <!-- Host -->
    <button
      type="button"
      class="detail-line"
      class:copied={copiedField === `${log.id}-host`}
      on:click|stopPropagation={() => handleCopy(log.host, `${log.id}-host`)}
    >
      <span class="line-key">host</span>
      <span class="line-value purple">{log.host}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-host` ? 'Copied!' : ''}</span>
    </button>

    <!-- Message -->
    <button
      type="button"
      class="detail-line msg"
      class:copied={copiedField === `${log.id}-message`}
      on:click|stopPropagation={() => handleCopy(log.message, `${log.id}-message`)}
    >
      <span class="line-key">message</span>
      <!-- eslint-disable-next-line svelte/no-at-html-tags -->
      <span class="line-value mono">{@html highlightedMessage}</span>
      <span class="copy-feedback">{copiedField === `${log.id}-message` ? 'Copied!' : ''}</span>
    </button>

    <!-- Meta fields -->
    {#if parsedMeta && typeof parsedMeta === 'object' && Object.keys(parsedMeta).length > 0}
      {#each Object.entries(parsedMeta) as [key, value]}
        <button
          type="button"
          class="detail-line meta"
          class:copied={copiedField === `${log.id}-${key}`}
          on:click|stopPropagation={() => handleCopy(String(value), `${log.id}-${key}`)}
        >
          <span class="line-key">{key}</span>
          <span class="line-value mono">{typeof value === 'object' ? JSON.stringify(value) : value}</span>
          <span class="copy-feedback">{copiedField === `${log.id}-${key}` ? 'Copied!' : ''}</span>
        </button>
      {/each}
    {/if}

    <!-- Trace ID -->
    {#if log.trace_id}
      <button
        type="button"
        class="detail-line trace"
        on:click|stopPropagation={handleFilterTrace}
        title="Filter by trace ID"
      >
        <span class="line-key">trace_id</span>
        <span class="line-value mono trace-link">{log.trace_id}</span>
        <span class="trace-action">Filter</span>
      </button>
    {/if}

    <!-- Request ID -->
    {#if log.request_id}
      <button
        type="button"
        class="detail-line trace"
        on:click|stopPropagation={handleFilterRequest}
        title="Filter by request ID"
      >
        <span class="line-key">request_id</span>
        <span class="line-value mono trace-link">{log.request_id}</span>
        <span class="trace-action">Filter</span>
      </button>
    {/if}

    <!-- Span ID -->
    {#if log.span_id}
      <button
        type="button"
        class="detail-line"
        on:click|stopPropagation={() => handleCopy(log.span_id)}
      >
        <span class="line-key">span_id</span>
        <span class="line-value mono">{log.span_id}</span>
      </button>
    {/if}

    <!-- Parent Span ID -->
    {#if log.parent_span_id}
      <button
        type="button"
        class="detail-line"
        on:click|stopPropagation={() => handleCopy(log.parent_span_id)}
      >
        <span class="line-key">parent_span</span>
        <span class="line-value mono">{log.parent_span_id}</span>
      </button>
    {/if}

    <!-- Raw log -->
    {#if log.raw && log.raw !== log.message}
      <div class="detail-line raw">
        <span class="line-key">raw</span>
        <pre class="line-value mono">{log.raw}</pre>
      </div>
    {/if}
  </div>

  <slot name="context" />
</div>

<style>
  .log-detail {
    padding: 12px 16px;
    border-left: 3px solid var(--border-color, #30363d);
    margin-left: 8px;
    max-width: 100%;
    overflow: hidden;
  }

  .detail-actions {
    display: flex;
    gap: 6px;
    margin-bottom: 10px;
  }

  .action-btn {
    padding: 4px 10px;
    background: transparent;
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-sm, 4px);
    color: var(--text-secondary, #8b949e);
    font-size: 11px;
    cursor: pointer;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .action-btn:hover {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .action-btn.context {
    color: var(--color-primary, #58a6ff);
    background: var(--bg-tertiary, #21262d);
  }

  .action-btn.context:hover {
    border-color: var(--color-primary, #58a6ff);
  }

  .action-btn.context.active {
    background: var(--color-primary-bg, rgba(56, 139, 253, 0.15));
    border-color: var(--color-primary, #58a6ff);
  }

  .action-btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
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
    border-radius: var(--radius-sm, 4px);
    cursor: pointer;
    width: 100%;
    text-align: left;
    background: transparent;
    border: none;
    font-family: inherit;
    font-size: inherit;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .detail-line:hover {
    background: var(--bg-secondary, #161b22);
  }

  .detail-line.copied {
    background: rgba(35, 134, 54, 0.2) !important;
    border-left: 3px solid var(--color-success, #3fb950);
  }

  .copy-feedback {
    flex-shrink: 0;
    font-size: 11px;
    color: var(--color-success, #3fb950);
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
    border-top: 1px solid var(--bg-tertiary, #21262d);
  }

  .detail-line.meta {
    opacity: 0.85;
  }

  .detail-line.raw {
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid var(--bg-tertiary, #21262d);
    flex-direction: column;
    gap: 4px;
    cursor: default;
  }

  .line-key {
    min-width: 80px;
    font-size: var(--text-sm, 12px);
    color: var(--text-muted, #6e7681);
  }

  .line-value {
    flex: 1;
    font-size: var(--text-base, 13px);
    color: var(--text-primary, #c9d1d9);
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }

  .line-value.mono {
    font-family: var(--font-mono, 'SFMono-Regular', Consolas, monospace);
    font-size: var(--text-sm, 12px);
  }

  .line-value.blue {
    color: var(--color-primary, #58a6ff);
  }

  .line-value.purple {
    color: var(--color-purple, #a371f7);
  }

  .detail-line.raw .line-value {
    white-space: pre-wrap;
    background: var(--bg-secondary, #161b22);
    padding: 8px;
    border-radius: var(--radius-sm, 4px);
    margin: 0;
  }

  /* Trace/Request ID styling */
  .detail-line.trace {
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    margin-top: 4px;
    border-radius: var(--radius-sm, 4px);
  }

  .detail-line.trace:hover {
    background: var(--bg-hover, #30363d);
    border-color: var(--color-primary, #58a6ff);
  }

  .trace-link {
    color: var(--color-primary, #58a6ff);
  }

  .trace-action {
    font-size: 11px;
    color: var(--text-secondary, #8b949e);
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 3px;
    flex-shrink: 0;
  }

  .detail-line.trace:hover .trace-action {
    background: var(--color-primary-bg, rgba(56, 139, 253, 0.15));
    color: var(--color-primary, #58a6ff);
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
