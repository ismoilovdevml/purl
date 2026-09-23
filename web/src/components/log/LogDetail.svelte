<!--
  LogDetail Component
  Expanded log details panel with copy functionality

  Usage:
  <LogDetail {log} {searchQuery} onfiltertrace={...} onfilterrequest={...} onshowcontext={...}>
    {#snippet context()}...{/snippet}
  </LogDetail>
-->
<script>
  import { getLevelColor } from '../../utils/colors.js';
  import { highlightText, copyToClipboard, stopPropagation } from '../../utils/dom.js';

  let {
    log,
    searchQuery = '',
    showContextButton = true,
    contextLoading = false,
    contextOpen = false,
    /** ({ traceId }) */
    onfiltertrace,
    /** ({ requestId }) */
    onfilterrequest,
    /** ({ logId }) */
    onshowcontext,
    /** Snippet rendered under the detail lines (the surrounding-logs panel) */
    context,
  } = $props();

  // Copy feedback state
  let copiedField = $state(null);
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
    onfiltertrace?.({ traceId: log.trace_id });
  }

  function handleFilterRequest() {
    onfilterrequest?.({ requestId: log.request_id });
  }

  function handleShowContext() {
    onshowcontext?.({ logId: log.id });
  }

  const levelColor = $derived(getLevelColor(log.level));
  const highlightedMessage = $derived(highlightText(log.message, searchQuery));
  const parsedMeta = $derived.by(() => {
    if (!log.meta) return null;
    try {
      return typeof log.meta === 'string' ? JSON.parse(log.meta) : log.meta;
    } catch {
      return null;
    }
  });
</script>

<!-- One click-to-copy line for a plain top-level field. -->
{#snippet copyLine(key, value, valueClass, valueStyle)}
  {@const id = `${log.id}-${key}`}
  <button
    type="button"
    class="detail-line"
    class:copied={copiedField === id}
    onclick={stopPropagation(() => handleCopy(value, id))}
  >
    <span class="line-key">{key}</span>
    <span class="line-value {valueClass}" style={valueStyle}>{value}</span>
    <span class="copy-feedback">{copiedField === id ? 'Copied!' : ''}</span>
  </button>
{/snippet}

<!-- A trace_id / request_id line: clicking filters the search by it. -->
{#snippet filterLine(key, value, title, onfilter)}
  <button
    type="button"
    class="detail-line trace"
    onclick={stopPropagation(onfilter)}
    {title}
  >
    <span class="line-key">{key}</span>
    <span class="line-value mono trace-link">{value}</span>
    <span class="trace-action">Filter</span>
  </button>
{/snippet}

<!-- A span id line: click copies, without the "Copied!" feedback. -->
{#snippet spanLine(key, value)}
  <button
    type="button"
    class="detail-line"
    onclick={stopPropagation(() => handleCopy(value))}
  >
    <span class="line-key">{key}</span>
    <span class="line-value mono">{value}</span>
  </button>
{/snippet}

<!-- Every handler below is wrapped in stopPropagation: clicks inside the
     detail panel must not reach the row's own click handler (which collapses it). -->
<div class="log-detail">
  <div class="detail-actions">
    <button class="action-btn" onclick={stopPropagation(() => handleCopy(log.raw || log.message))} title="Copy raw log">
      Copy
    </button>
    <button class="action-btn" onclick={stopPropagation(() => handleCopy(JSON.stringify(log, null, 2)))} title="Copy as JSON">
      JSON
    </button>
    {#if showContextButton}
      <button
        class="action-btn context"
        class:active={contextOpen}
        onclick={stopPropagation(handleShowContext)}
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
    {@render copyLine('timestamp', log.timestamp, 'mono')}
    {@render copyLine('level', log.level, '', `color: ${levelColor}`)}
    {@render copyLine('service', log.service, 'blue')}
    {@render copyLine('host', log.host, 'purple')}

    <!-- Message -->
    <button
      type="button"
      class="detail-line msg"
      class:copied={copiedField === `${log.id}-message`}
      onclick={stopPropagation(() => handleCopy(log.message, `${log.id}-message`))}
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
          onclick={stopPropagation(() => handleCopy(String(value), `${log.id}-${key}`))}
        >
          <span class="line-key">{key}</span>
          <span class="line-value mono">{typeof value === 'object' ? JSON.stringify(value) : value}</span>
          <span class="copy-feedback">{copiedField === `${log.id}-${key}` ? 'Copied!' : ''}</span>
        </button>
      {/each}
    {/if}

    {#if log.trace_id}
      {@render filterLine('trace_id', log.trace_id, 'Filter by trace ID', handleFilterTrace)}
    {/if}
    {#if log.request_id}
      {@render filterLine('request_id', log.request_id, 'Filter by request ID', handleFilterRequest)}
    {/if}
    {#if log.span_id}
      {@render spanLine('span_id', log.span_id)}
    {/if}
    {#if log.parent_span_id}
      {@render spanLine('parent_span', log.parent_span_id)}
    {/if}

    <!-- Raw log -->
    {#if log.raw && log.raw !== log.message}
      <div class="detail-line raw">
        <span class="line-key">raw</span>
        <pre class="line-value mono">{log.raw}</pre>
      </div>
    {/if}
  </div>

  {@render context?.()}
</div>

<style>
  .log-detail {
    padding: 12px 16px;
    border-left: 3px solid var(--border-color);
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
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: 11px;
    cursor: pointer;
    transition: var(--transition-fast);
  }

  .action-btn:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .action-btn.context {
    color: var(--color-primary);
    background: var(--bg-tertiary);
  }

  .action-btn.context:hover {
    border-color: var(--color-primary);
  }

  .action-btn.context.active {
    background: var(--color-primary-bg-alt);
    border-color: var(--color-primary);
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
    border-radius: var(--radius-sm);
    cursor: pointer;
    width: 100%;
    text-align: left;
    background: transparent;
    border: none;
    font-family: inherit;
    font-size: inherit;
    transition: var(--transition-fast);
  }

  .detail-line:hover {
    background: var(--bg-secondary);
  }

  .detail-line.copied {
    background: rgba(35, 134, 54, 0.2) !important;
    border-left: 3px solid var(--color-success);
  }

  .copy-feedback {
    flex-shrink: 0;
    font-size: 11px;
    color: var(--color-success);
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
    border-top: 1px solid var(--bg-tertiary);
  }

  .detail-line.meta {
    opacity: 0.85;
  }

  .detail-line.raw {
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid var(--bg-tertiary);
    flex-direction: column;
    gap: 4px;
    cursor: default;
  }

  .line-key {
    min-width: 80px;
    font-size: var(--text-sm);
    color: var(--text-muted);
  }

  .line-value {
    flex: 1;
    font-size: var(--text-base);
    color: var(--text-primary);
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }

  .line-value.mono {
    font-family: var(--font-mono);
    font-size: var(--text-sm);
  }

  .line-value.blue {
    color: var(--color-primary);
  }

  .line-value.purple {
    color: var(--color-purple);
  }

  .detail-line.raw .line-value {
    white-space: pre-wrap;
    background: var(--bg-secondary);
    padding: 8px;
    border-radius: var(--radius-sm);
    margin: 0;
  }

  /* Trace/Request ID styling */
  .detail-line.trace {
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    margin-top: 4px;
    border-radius: var(--radius-sm);
  }

  .detail-line.trace:hover {
    background: var(--bg-hover);
    border-color: var(--color-primary);
  }

  .trace-link {
    color: var(--color-primary);
  }

  .trace-action {
    font-size: 11px;
    color: var(--text-secondary);
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 3px;
    flex-shrink: 0;
  }

  .detail-line.trace:hover .trace-action {
    background: var(--color-primary-bg-alt);
    color: var(--color-primary);
  }

  /* Search highlight */
  :global(.search-highlight) {
    background: var(--color-highlight);
    color: var(--bg-primary);
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }
</style>
