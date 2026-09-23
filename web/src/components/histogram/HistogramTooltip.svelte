<!--
  HistogramTooltip
  Hover card for one histogram bucket: its timestamp, per-level counts, the
  change vs the same bucket of the previous period, and an anomaly callout.
  Positioned absolutely inside the chart wrapper by HistogramChart.
-->
<script>
  let {
    /** { x, y, data, prevData, changePercent, isAnomaly, avgCount } */
    tooltip,
    /** The previous-period comparison is on (shows the Previous row) */
    showComparison = false,
  } = $props();

  function formatFullTime(timestamp) {
    if (!timestamp) return '';
    const date = new Date(timestamp);
    return date.toLocaleString('en-US', {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false
    });
  }
</script>

<div class="tooltip" class:anomaly={tooltip.isAnomaly} style="left: {tooltip.x}px; top: {tooltip.y}px;">
  <div class="tooltip-time">
    {formatFullTime(tooltip.data.time)}
    {#if tooltip.isAnomaly}
      <span class="tooltip-anomaly-tag">ANOMALY</span>
    {/if}
  </div>
  {#if tooltip.isAnomaly}
    <div class="tooltip-anomaly-desc">Spike: {tooltip.data.count} vs avg {tooltip.avgCount} logs</div>
  {/if}
  <div class="tooltip-stats">
    <div class="tooltip-row">
      <span class="tooltip-dot total"></span>
      <span>Total</span>
      <span class="tooltip-value">
        {tooltip.data.count.toLocaleString()}
        {#if tooltip.changePercent !== null}
          <span class="tooltip-change" class:positive={tooltip.changePercent > 0} class:negative={tooltip.changePercent < 0}>
            {tooltip.changePercent > 0 ? '+' : ''}{tooltip.changePercent}%
          </span>
        {/if}
      </span>
    </div>
    {#if tooltip.data.errors}
      <div class="tooltip-row">
        <span class="tooltip-dot error"></span>
        <span>Errors</span>
        <span class="tooltip-value">{tooltip.data.errors.toLocaleString()}</span>
      </div>
    {/if}
    {#if tooltip.data.warnings}
      <div class="tooltip-row">
        <span class="tooltip-dot warning"></span>
        <span>Warnings</span>
        <span class="tooltip-value">{tooltip.data.warnings.toLocaleString()}</span>
      </div>
    {/if}
    {#if tooltip.data.info}
      <div class="tooltip-row">
        <span class="tooltip-dot info"></span>
        <span>Info</span>
        <span class="tooltip-value">{tooltip.data.info.toLocaleString()}</span>
      </div>
    {/if}
    {#if showComparison && tooltip.prevData}
      <div class="tooltip-divider"></div>
      <div class="tooltip-row prev">
        <span class="tooltip-dot prev"></span>
        <span>Previous</span>
        <span class="tooltip-value">{tooltip.prevData.count.toLocaleString()}</span>
      </div>
    {/if}
  </div>
  <div class="tooltip-hint">Click to filter</div>
</div>

<style>
  .tooltip {
    position: absolute;
    transform: translate(-50%, -100%);
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 10px 12px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
    pointer-events: none;
    z-index: 100;
    min-width: 160px;
  }

  .tooltip.anomaly {
    border-color: #f85149;
    box-shadow: 0 0 12px rgba(248, 81, 73, 0.3);
  }

  .tooltip-time {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 11px;
    color: #8b949e;
    margin-bottom: 8px;
    padding-bottom: 6px;
    border-bottom: 1px solid #21262d;
  }

  .tooltip-anomaly-tag {
    font-size: 11px;
    padding: 1px 4px;
    background: #f85149;
    color: #fff;
    border-radius: 3px;
    font-weight: 700;
  }

  .tooltip-anomaly-desc {
    font-size: 11px;
    color: #f85149;
    padding: 3px 0 2px;
    border-bottom: 1px solid rgba(248, 81, 73, 0.2);
    margin-bottom: 2px;
  }

  .tooltip-stats {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .tooltip-row {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: #c9d1d9;
  }

  .tooltip-row.prev {
    color: #8b949e;
  }

  .tooltip-dot {
    width: 8px;
    height: 8px;
    border-radius: 2px;
  }

  .tooltip-dot.total { background: #58a6ff; }
  .tooltip-dot.error { background: #f85149; }
  .tooltip-dot.warning { background: #d29922; }
  .tooltip-dot.info { background: #3fb950; }
  .tooltip-dot.prev {
    background: transparent;
    border: 2px dashed #8b949e;
  }

  .tooltip-value {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 6px;
    font-family: var(--font-mono);
    font-weight: 500;
  }

  .tooltip-change {
    font-size: 10px;
    font-weight: 600;
  }

  .tooltip-change.positive { color: #3fb950; }
  .tooltip-change.negative { color: #f85149; }

  .tooltip-divider {
    height: 1px;
    background: #21262d;
    margin: 4px 0;
  }

  .tooltip-hint {
    font-size: 10px;
    color: #848d97;
    text-align: center;
    margin-top: 8px;
    padding-top: 6px;
    border-top: 1px solid #21262d;
  }
</style>
