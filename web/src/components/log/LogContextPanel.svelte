<!--
  LogContextPanel Component
  Shows surrounding logs before and after the selected log

  Usage:
  <LogContextPanel {currentLog} {beforeLogs} {afterLogs} onclose={hide} />
-->
<script>
  import { formatTimestamp } from '../../utils/format.js';
  import { getLevelColor } from '../../utils/colors.js';
  import Icon from '../ui/Icon.svelte';
  import { arrowLeft } from '../ui/icons.js';

  let {
    currentLog,
    beforeLogs = [],
    afterLogs = [],
    beforeCount = 0,
    afterCount = 0,
    /** () => void */
    onclose,
  } = $props();

  function handleClose(event) {
    event.stopPropagation();
    onclose?.();
  }
</script>

<div class="context-panel">
  <div class="context-header">
    <span class="context-title">
      Context: {beforeCount} before, {afterCount} after
    </span>
    <button class="context-close" onclick={handleClose}>
      Close
    </button>
  </div>
  <div class="context-logs">
    <!-- Before logs -->
    {#each beforeLogs as log}
      <div class="context-log before">
        <span class="ctx-time">{formatTimestamp(log.timestamp)}</span>
        <span class="ctx-level" style="color: {getLevelColor(log.level)}">{log.level}</span>
        <span class="ctx-message">{log.message}</span>
      </div>
    {/each}

    <!-- Current log marker -->
    <div class="context-log current">
      <span class="ctx-time">{formatTimestamp(currentLog.timestamp)}</span>
      <span class="ctx-level" style="color: {getLevelColor(currentLog.level)}">{currentLog.level}</span>
      <span class="ctx-message">{currentLog.message}</span>
      <span class="ctx-marker"><Icon icon={arrowLeft} size={12} strokeWidth={3} /> Current</span>
    </div>

    <!-- After logs -->
    {#each afterLogs as log}
      <div class="context-log after">
        <span class="ctx-time">{formatTimestamp(log.timestamp)}</span>
        <span class="ctx-level" style="color: {getLevelColor(log.level)}">{log.level}</span>
        <span class="ctx-message">{log.message}</span>
      </div>
    {/each}
  </div>
</div>

<style>
  .context-panel {
    margin-top: 12px;
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    background: var(--bg-primary);
    overflow: hidden;
  }

  .context-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    background: var(--bg-secondary);
    border-bottom: 1px solid var(--border-color);
  }

  .context-title {
    font-size: var(--text-sm);
    color: var(--text-secondary);
    font-weight: 500;
  }

  .context-close {
    padding: 2px 8px;
    background: transparent;
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: 11px;
    cursor: pointer;
    transition: var(--transition-fast);
  }

  .context-close:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .context-logs {
    max-height: 400px;
    overflow-y: auto;
  }

  .context-log {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 6px 12px;
    font-size: var(--text-sm);
    border-bottom: 1px solid var(--bg-tertiary);
  }

  .context-log:last-child {
    border-bottom: none;
  }

  .context-log.before {
    background: rgba(22, 27, 34, 0.5);
    opacity: 0.7;
  }

  .context-log.after {
    background: rgba(22, 27, 34, 0.5);
    opacity: 0.7;
  }

  .context-log.current {
    background: var(--color-primary-bg-subtle);
    border-left: 3px solid var(--color-primary);
    font-weight: 500;
  }

  .ctx-time {
    font-family: var(--font-mono);
    color: var(--text-secondary);
    flex-shrink: 0;
    width: 70px;
  }

  .ctx-level {
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
    width: 60px;
  }

  .ctx-message {
    flex: 1;
    font-family: var(--font-mono);
    color: var(--text-primary);
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .ctx-marker {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    color: var(--color-primary);
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
  }
</style>
