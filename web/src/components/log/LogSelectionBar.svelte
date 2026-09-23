<!--
  LogSelectionBar
  Bar above the log table while one or more rows are checked: row count plus
  export / AI analyze / clear actions. The AI button only appears when AI is
  enabled and configured.
-->
<script>
  import { aiEnabled, aiConfigured } from '../../stores/ai.js';
  import Icon from '../ui/Icon.svelte';
  import { alertCircleSolid, close, fileText } from '../ui/icons.js';

  let {
    /** Number of checked rows (> 0 while the bar is shown) */
    count,
    /** () => void — download the checked rows as CSV */
    onexport,
    /** () => void — open the AI analysis panel for the checked rows */
    onanalyze,
    /** () => void — uncheck every row */
    onclear,
  } = $props();
</script>

<div class="selection-bar">
  <span class="selection-count"><strong>{count}</strong> {count === 1 ? 'row' : 'rows'} selected</span>
  <button class="selection-action-btn" onclick={onexport}>
    <Icon icon={fileText} size={12} strokeWidth={3} />
    Export selected
  </button>
  {#if $aiEnabled && $aiConfigured}
    <button class="selection-action-btn ai-analyze-btn" onclick={onanalyze}>
      <Icon icon={alertCircleSolid} size={12} />
      AI Analyze
    </button>
  {/if}
  <button class="selection-clear-btn" onclick={onclear}>
    <Icon icon={close} size={12} strokeWidth={3} />
    Clear selection
  </button>
</div>

<style>
  .selection-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 7px 12px;
    background: var(--color-primary-bg-subtle);
    border-bottom: 1px solid var(--color-primary);
    font-size: var(--text-sm);
  }

  .selection-count {
    color: var(--text-primary);
    margin-right: 4px;
  }

  .selection-count strong {
    color: var(--color-primary);
  }

  .selection-action-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 10px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: var(--text-sm);
    cursor: pointer;
    transition: background 0.15s;
  }

  .selection-action-btn:hover {
    background: var(--border-color);
  }

  .selection-clear-btn {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 3px 10px;
    background: transparent;
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: var(--text-sm);
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }

  .selection-clear-btn:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .ai-analyze-btn {
    background: rgba(163, 113, 247, 0.1);
    border-color: rgba(163, 113, 247, 0.4);
    color: #a371f7;
  }

  .ai-analyze-btn:hover {
    background: rgba(163, 113, 247, 0.2);
  }
</style>
