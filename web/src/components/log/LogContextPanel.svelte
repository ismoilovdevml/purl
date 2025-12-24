<!--
  LogContextPanel Component
  Shows surrounding logs before and after the selected log

  Usage:
  <LogContextPanel {currentLog} {beforeLogs} {afterLogs} on:close />
-->
<script>
  import { createEventDispatcher } from 'svelte';
  import { formatTimestamp } from '../../utils/format.js';
  import { getLevelColor } from '../../utils/colors.js';

  export let currentLog;
  export let beforeLogs = [];
  export let afterLogs = [];
  export let beforeCount = 0;
  export let afterCount = 0;

  const dispatch = createEventDispatcher();

  function handleClose() {
    dispatch('close');
  }
</script>

<div class="context-panel">
  <div class="context-header">
    <span class="context-title">
      Context: {beforeCount} before, {afterCount} after
    </span>
    <button class="context-close" on:click|stopPropagation={handleClose}>
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
      <span class="ctx-marker">← Current</span>
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
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-md, 6px);
    background: var(--bg-primary, #0d1117);
    overflow: hidden;
  }

  .context-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    background: var(--bg-secondary, #161b22);
    border-bottom: 1px solid var(--border-color, #30363d);
  }

  .context-title {
    font-size: var(--text-sm, 12px);
    color: var(--text-secondary, #8b949e);
    font-weight: 500;
  }

  .context-close {
    padding: 2px 8px;
    background: transparent;
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-sm, 4px);
    color: var(--text-secondary, #8b949e);
    font-size: 11px;
    cursor: pointer;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .context-close:hover {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
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
    font-size: var(--text-sm, 12px);
    border-bottom: 1px solid var(--bg-tertiary, #21262d);
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
    background: var(--color-primary-bg, rgba(56, 139, 253, 0.08));
    border-left: 3px solid var(--color-primary, #58a6ff);
    font-weight: 500;
  }

  .ctx-time {
    font-family: var(--font-mono, 'SFMono-Regular', Consolas, monospace);
    color: var(--text-secondary, #8b949e);
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
    font-family: var(--font-mono, 'SFMono-Regular', Consolas, monospace);
    color: var(--text-primary, #c9d1d9);
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .ctx-marker {
    color: var(--color-primary, #58a6ff);
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
  }
</style>
