<!--
  DashboardWidget
  One widget card on a dashboard: header with a remove button, and the body
  rendered for the widget's type from the last executeWidget() result.
  `result` is undefined while the widget is still loading.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { close } from '../ui/icons.js';

  let {
    /** { id, type, title, query } */
    widget,
    /** executeWidget() result, or undefined while loading */
    result,
    /** () => void — remove this widget from the dashboard */
    onremove,
  } = $props();

  function formatNumber(n) {
    if (n === undefined || n === null) return '0';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n.toLocaleString();
  }
</script>

<div class="widget-card">
  <div class="widget-header">
    <span class="widget-title">{widget.title}</span>
    <button
      class="widget-close"
      onclick={onremove}
      aria-label="Remove widget {widget.title}"
    >
      <Icon icon={close} size={12} strokeWidth={3} />
    </button>
  </div>
  <div class="widget-body">
    {#if !result}
      <div class="widget-loading">Loading...</div>
    {:else if result.error}
      <div class="widget-error">{result.error}</div>
    {:else if widget.type === 'counter'}
      <div class="counter-value">{formatNumber(result.value)}</div>
    {:else if widget.type === 'chart'}
      <div class="chart-placeholder">
        {#each (result.data || []).slice(-20) as point}
          <div class="chart-bar" style="height: {Math.max(2, (point.count / Math.max(...(result.data || []).map(p => p.count || 1))) * 100)}%"></div>
        {/each}
      </div>
    {:else if widget.type === 'table'}
      <table class="widget-table">
        <tbody>
          {#each (result.data || []).slice(0, 10) as row}
            <tr>
              <td>{row.value}</td>
              <td class="count">{formatNumber(row.count)}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    {:else if widget.type === 'log_stream'}
      <div class="log-stream">
        {#each (result.logs || []).slice(0, 10) as log}
          <div class="log-line">
            <span class="log-level level-{(log.level || '').toLowerCase()}">{log.level}</span>
            <span class="log-msg">{log.message}</span>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .widget-card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
    min-height: 200px;
  }

  .widget-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    border-bottom: 1px solid #21262d;
  }

  .widget-title {
    font-size: 13px;
    font-weight: 600;
    color: #c9d1d9;
  }

  .widget-close {
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    color: #8b949e;
    cursor: pointer;
    padding: 2px 4px;
    line-height: 1;
  }

  .widget-close:hover {
    color: #f85149;
  }

  .widget-body {
    padding: 14px;
  }

  .widget-loading, .widget-error {
    color: #8b949e;
    font-size: 13px;
    text-align: center;
    padding: 20px;
  }

  .widget-error {
    color: #f85149;
  }

  .counter-value {
    font-size: 36px;
    font-weight: 700;
    color: #58a6ff;
    text-align: center;
    padding: 20px;
  }

  .chart-placeholder {
    display: flex;
    align-items: flex-end;
    gap: 2px;
    height: 120px;
    padding-top: 10px;
  }

  .chart-bar {
    flex: 1;
    background: #58a6ff;
    border-radius: 2px 2px 0 0;
    min-height: 2px;
    transition: height 0.3s;
  }

  .widget-table {
    width: 100%;
    font-size: 13px;
  }

  .widget-table td {
    padding: 6px 8px;
    border-bottom: 1px solid #21262d;
  }

  .widget-table .count {
    text-align: right;
    color: #58a6ff;
    font-weight: 500;
  }

  .log-stream {
    max-height: 200px;
    overflow-y: auto;
  }

  .log-line {
    display: flex;
    gap: 8px;
    padding: 3px 0;
    font-size: 12px;
    font-family: var(--font-mono);
  }

  .log-level {
    flex-shrink: 0;
    width: 56px;
    text-align: center;
    font-size: 10px;
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
  }

  .level-error, .level-critical, .level-emergency {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
  }

  .level-warning {
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
  }

  .level-info, .level-notice {
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
  }

  .level-debug, .level-trace {
    background: rgba(139, 148, 158, 0.15);
    color: #8b949e;
  }

  .log-msg {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: #c9d1d9;
  }
</style>
