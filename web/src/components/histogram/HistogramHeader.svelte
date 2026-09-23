<!--
  HistogramHeader
  Title row of the log-activity histogram: the time-range badge, an anomaly
  count, and the summary stats (total with change vs the previous period,
  average per bucket, error and warning totals).
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { barChartSolid, alertCircleSolid, arrowUp, arrowDown, arrowRight } from '../ui/icons.js';
  import { formatHistogramCount as formatNumber } from '../../utils/histogram.js';

  let {
    /** Current time range label, e.g. '15m' */
    timeRange,
    /** Number of anomalous buckets */
    anomalyCount = 0,
    /** Total logs across all buckets */
    totalLogs = 0,
    /** % change vs the previous period, or null when there is none */
    totalChangePercent = null,
    /** Average logs per bucket */
    avgCount = 0,
    /** Total error / warning logs */
    errorCount = 0,
    warnCount = 0,
  } = $props();
</script>

<div class="histogram-header">
  <div class="header-left">
    <Icon icon={barChartSolid} size={16} />
    <span class="histogram-title">Log Activity</span>
    <span class="time-range-badge">{timeRange}</span>
    {#if anomalyCount > 0}
      <span class="anomaly-badge" title="Anomalies detected">
        <Icon icon={alertCircleSolid} size={12} />
        {anomalyCount}
      </span>
    {/if}
  </div>
  <div class="header-stats">
    <div class="stat">
      <span class="stat-value">
        {formatNumber(totalLogs)}
        {#if totalChangePercent !== null}
          <span class="change-indicator" class:positive={totalChangePercent > 0} class:negative={totalChangePercent < 0}>
            <Icon
              icon={totalChangePercent > 0 ? arrowUp : totalChangePercent < 0 ? arrowDown : arrowRight}
              size={11}
              strokeWidth={3}
            />{Math.abs(totalChangePercent)}%
          </span>
        {/if}
      </span>
      <span class="stat-label">Total</span>
    </div>
    <div class="stat-divider"></div>
    <div class="stat">
      <span class="stat-value avg">{formatNumber(avgCount)}</span>
      <span class="stat-label">Avg/bucket</span>
    </div>
    {#if errorCount > 0}
      <div class="stat-divider"></div>
      <div class="stat error">
        <span class="stat-value">{formatNumber(errorCount)}</span>
        <span class="stat-label">Errors</span>
      </div>
    {/if}
    {#if warnCount > 0}
      <div class="stat-divider"></div>
      <div class="stat warning">
        <span class="stat-value">{formatNumber(warnCount)}</span>
        <span class="stat-label">Warnings</span>
      </div>
    {/if}
  </div>
</div>

<style>
  .histogram-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  /* :global — Icon renders its SVG inside its own component scope. */
  .header-left :global(svg) {
    color: #58a6ff;
  }

  .histogram-title {
    font-size: 13px;
    font-weight: 600;
    color: #c9d1d9;
  }

  .time-range-badge {
    font-size: 11px;
    padding: 2px 8px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 12px;
    color: #8b949e;
  }

  .anomaly-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    padding: 2px 8px;
    background: rgba(248, 81, 73, 0.15);
    border: 1px solid #f85149;
    border-radius: 12px;
    color: #f85149;
    font-weight: 600;
  }

  .header-stats {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .stat {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
  }

  .stat-value {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 14px;
    font-weight: 600;
    font-family: var(--font-mono);
    color: #c9d1d9;
  }

  .change-indicator {
    display: inline-flex;
    align-items: center;
    gap: 1px;
    font-size: 11px;
    padding: 1px 4px;
    border-radius: 4px;
    font-weight: 600;
  }

  .change-indicator.positive {
    background: rgba(63, 185, 80, 0.15);
    color: #3fb950;
  }

  .change-indicator.negative {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
  }

  .stat-value.avg {
    color: #58a6ff;
  }

  .stat.error .stat-value {
    color: #f85149;
  }

  .stat.warning .stat-value {
    color: #d29922;
  }

  .stat-label {
    font-size: 10px;
    color: #848d97;
    text-transform: uppercase;
  }

  .stat-divider {
    width: 1px;
    height: 24px;
    background: #30363d;
  }
</style>
