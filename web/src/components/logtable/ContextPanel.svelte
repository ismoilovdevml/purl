<script>
  import { formatTimestamp, getLevelColor } from '../../stores/logs.js';

  export let contextData;
  export let log;
  export let onClose;
</script>

<div class="context-panel">
  <div class="context-header">
    <span class="context-title">
      Context: {contextData.before_count} before, {contextData.after_count} after
    </span>
    <button class="context-close" on:click|stopPropagation={onClose}>
      Close
    </button>
  </div>
  <div class="context-logs">
    <!-- Before logs -->
    {#each contextData.before_logs as ctxLog}
      <div class="context-log before">
        <span class="ctx-time">{formatTimestamp(ctxLog.timestamp)}</span>
        <span class="ctx-level" style="color: {getLevelColor(ctxLog.level)}">{ctxLog.level}</span>
        <span class="ctx-message">{ctxLog.message}</span>
      </div>
    {/each}

    <!-- Current log marker -->
    <div class="context-log current">
      <span class="ctx-time">{formatTimestamp(log.timestamp)}</span>
      <span class="ctx-level" style="color: {getLevelColor(log.level)}">{log.level}</span>
      <span class="ctx-message">{log.message}</span>
      <span class="ctx-marker">← Current</span>
    </div>

    <!-- After logs -->
    {#each contextData.after_logs as ctxLog}
      <div class="context-log after">
        <span class="ctx-time">{formatTimestamp(ctxLog.timestamp)}</span>
        <span class="ctx-level" style="color: {getLevelColor(ctxLog.level)}">{ctxLog.level}</span>
        <span class="ctx-message">{ctxLog.message}</span>
      </div>
    {/each}
  </div>
</div>

<style>
  .context-panel {
    margin-top: 12px;
    border: 1px solid #30363d;
    border-radius: 6px;
    background: #0d1117;
    overflow: hidden;
  }

  .context-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    background: #161b22;
    border-bottom: 1px solid #30363d;
  }

  .context-title {
    font-size: 12px;
    color: #8b949e;
    font-weight: 500;
  }

  .context-close {
    padding: 2px 8px;
    background: transparent;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #8b949e;
    font-size: 11px;
    cursor: pointer;
  }

  .context-close:hover {
    background: #21262d;
    color: #c9d1d9;
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
    font-size: 12px;
    border-bottom: 1px solid #21262d;
  }

  .context-log:last-child {
    border-bottom: none;
  }

  .context-log.before {
    background: #161b2280;
    opacity: 0.7;
  }

  .context-log.after {
    background: #161b2280;
    opacity: 0.7;
  }

  .context-log.current {
    background: #388bfd15;
    border-left: 3px solid #58a6ff;
    font-weight: 500;
  }

  .ctx-time {
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #8b949e;
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
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #c9d1d9;
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .ctx-marker {
    color: #58a6ff;
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
  }
</style>
