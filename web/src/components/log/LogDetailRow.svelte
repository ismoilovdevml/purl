<!--
  LogDetailRow
  The full-width row under an expanded log: LogDetail, the optional
  surrounding-logs panel, and the "Explain with AI" action.
  Context state lives in LogTable (it survives collapsing the row).
-->
<script>
  import LogDetail from './LogDetail.svelte';
  import LogContextPanel from './LogContextPanel.svelte';
  import Icon from '../ui/Icon.svelte';
  import { alertCircleSolid } from '../ui/icons.js';
  import { aiEnabled, aiConfigured } from '../../stores/ai.js';
  import { filterByTrace, filterByRequest } from '../../stores/logs.js';

  let {
    log,
    searchQuery = '',
    /** Number of table columns the row spans */
    colspan,
    /** Surrounding-logs request in flight for this log */
    contextLoading = false,
    /** fetchLogContext() result for this log, or undefined when closed */
    contextData,
    /** () => void — load the context, or hide it when already open */
    ontogglecontext,
    /** () => void */
    onclosecontext,
    /** () => void — open the AI explain modal for this log */
    onexplain,
  } = $props();

  function handleExplain(event) {
    event.stopPropagation();
    onexplain?.();
  }
</script>

<tr class="detail-row">
  <td {colspan}>
    <LogDetail
      {log}
      {searchQuery}
      {contextLoading}
      contextOpen={!!contextData}
      onfiltertrace={({ traceId }) => filterByTrace(traceId)}
      onfilterrequest={({ requestId }) => filterByRequest(requestId)}
      onshowcontext={ontogglecontext}
    >
      {#snippet context()}
        {#if contextData}
          <LogContextPanel
            currentLog={log}
            beforeLogs={contextData.before_logs}
            afterLogs={contextData.after_logs}
            beforeCount={contextData.before_count}
            afterCount={contextData.after_count}
            onclose={onclosecontext}
          />
        {/if}
      {/snippet}
    </LogDetail>
    {#if $aiEnabled && $aiConfigured}
      <div class="ai-explain-bar">
        <button class="ai-explain-btn" onclick={handleExplain}>
          <Icon icon={alertCircleSolid} size={12} />
          Explain with AI
        </button>
      </div>
    {/if}
  </td>
</tr>

<style>
  /* The generic `td` rule lives in LogTable's scope and no longer reaches this
     cell, so its border and alignment are repeated here. */
  .detail-row td {
    padding: 0;
    border-bottom: 1px solid var(--bg-tertiary);
    vertical-align: top;
    background: var(--bg-primary);
  }

  /* LogTable's compact-mode cell padding used to win over `padding: 0`. */
  :global(.log-table.compact) .detail-row td {
    padding: 4px 10px;
  }

  .ai-explain-bar {
    padding: 6px 12px;
    border-top: 1px solid var(--bg-tertiary);
    background: var(--bg-primary);
  }

  .ai-explain-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 10px;
    background: rgba(163, 113, 247, 0.08);
    border: 1px solid rgba(163, 113, 247, 0.3);
    border-radius: var(--radius-sm);
    color: #a371f7;
    font-size: var(--text-sm);
    cursor: pointer;
    transition: background 0.15s;
  }

  .ai-explain-btn:hover {
    background: rgba(163, 113, 247, 0.15);
  }
</style>
