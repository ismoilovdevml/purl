<script>
  import { onMount, createEventDispatcher } from 'svelte';
  import { histogram, timeRange, previousHistogram, fetchPreviousHistogram } from '../stores/logs.js';
  import Icon from './ui/Icon.svelte';
  import {
    barChartSolid,
    alertCircleSolid,
    columns,
    textLines,
    arrowUp,
    arrowDown,
    arrowRight,
  } from './ui/icons.js';

  const dispatch = createEventDispatcher();

  let canvas;
  let container;
  let tooltip = { show: false, x: 0, y: 0, data: null, prevData: null, changePercent: null };
  let hoveredBar = -1;
  let isDragging = false;
  let dragStart = null;
  let dragEnd = null;
  let selectionRect = null;
  let showComparison = false;

  // Stats - single pass calculation for performance
  function calculateAllStats(data) {
    if (data.length === 0) {
      return { total: 0, max: 1, errors: 0, warnings: 0, avg: 0, stdDev: 0, anomalies: [] };
    }

    let total = 0, errors = 0, warnings = 0, max = 1;
    const counts = [];

    for (const d of data) {
      total += d.count;
      errors += d.errors || 0;
      warnings += d.warnings || 0;
      if (d.count > max) max = d.count;
      counts.push(d.count);
    }

    const avg = Math.round(total / data.length);
    const mean = total / data.length;
    let sumSquares = 0;
    for (const c of counts) {
      sumSquares += (c - mean) ** 2;
    }
    const stdDev = Math.sqrt(sumSquares / data.length);
    const threshold = avg + (stdDev * 2);
    const anomalies = data.map((d, i) => d.count > threshold ? i : -1).filter(i => i >= 0);

    return { total, max, errors, warnings, avg, stdDev, anomalies, threshold };
  }

  $: stats = calculateAllStats($histogram);
  $: totalLogs = stats.total;
  $: maxCount = stats.max;
  $: avgCount = stats.avg;
  $: errorCount = stats.errors;
  $: warnCount = stats.warnings;
  $: anomalies = stats.anomalies;

  // Previous period stats for comparison - single pass
  $: prevTotalLogs = $previousHistogram.reduce((sum, d) => sum + d.count, 0);
  $: totalChangePercent = prevTotalLogs > 0
    ? Math.round(((totalLogs - prevTotalLogs) / prevTotalLogs) * 100)
    : null;

  $: if ($histogram.length > 0 && canvas) {
    drawHistogram();
  }

  // Fetch previous period when comparison is enabled
  $: if (showComparison && $histogram.length > 0) {
    fetchPreviousHistogram();
  }

  function getBarDimensions() {
    const rect = container?.getBoundingClientRect();
    if (!rect) return null;
    const width = rect.width;
    const height = 120; // Increased height for comparison line
    const padding = { left: 50, right: 20, top: 15, bottom: 30 };
    const chartWidth = width - padding.left - padding.right;
    const chartHeight = height - padding.top - padding.bottom;
    const barCount = $histogram.length || 1;
    const gap = 2;
    const totalGapWidth = (barCount - 1) * gap;
    const barWidth = Math.max(2, (chartWidth - totalGapWidth) / barCount);
    return { width, height, padding, chartWidth, chartHeight, barWidth, gap };
  }

  function drawHistogram() {
    const ctx = canvas.getContext('2d');
    const dims = getBarDimensions();
    if (!dims) return;

    const { width, height, padding, chartHeight, barWidth, gap } = dims;

    // Consider previous data for max calculation when comparing
    const prevMax = showComparison && $previousHistogram.length > 0
      ? Math.max(...$previousHistogram.map(d => d.count))
      : 0;
    const effectiveMax = Math.max(maxCount, prevMax, 1);

    canvas.width = width * window.devicePixelRatio;
    canvas.height = height * window.devicePixelRatio;
    canvas.style.width = width + 'px';
    canvas.style.height = height + 'px';
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    // Clear
    ctx.clearRect(0, 0, width, height);

    if ($histogram.length === 0) return;

    // Draw grid lines
    ctx.strokeStyle = '#21262d';
    ctx.lineWidth = 1;
    const gridLines = 4;
    for (let i = 0; i <= gridLines; i++) {
      const y = padding.top + (chartHeight / gridLines) * i;
      ctx.beginPath();
      ctx.moveTo(padding.left, y);
      ctx.lineTo(width - padding.right, y);
      ctx.stroke();

      // Y-axis labels
      const value = Math.round(effectiveMax - (effectiveMax / gridLines) * i);
      ctx.fillStyle = '#6e7681';
      ctx.font = '10px SFMono-Regular, Consolas, monospace';
      ctx.textAlign = 'right';
      ctx.fillText(formatNumber(value), padding.left - 8, y + 3);
    }

    // Draw previous period comparison line (dotted)
    if (showComparison && $previousHistogram.length > 0) {
      ctx.strokeStyle = '#8b949e';
      ctx.lineWidth = 2;
      ctx.setLineDash([4, 4]);
      ctx.beginPath();

      $previousHistogram.forEach((item, i) => {
        if (i >= $histogram.length) return;
        const x = padding.left + i * (barWidth + gap) + barWidth / 2;
        const y = height - padding.bottom - (item.count / effectiveMax) * chartHeight;
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      });
      ctx.stroke();
      ctx.setLineDash([]);
    }

    // Draw bars with stacked levels
    $histogram.forEach((item, i) => {
      const x = padding.left + i * (barWidth + gap);
      const totalHeight = (item.count / effectiveMax) * chartHeight;
      const isAnomaly = anomalies.includes(i);

      // Calculate segment heights
      const errorHeight = item.errors ? (item.errors / item.count) * totalHeight : 0;
      const warnHeight = item.warnings ? (item.warnings / item.count) * totalHeight : 0;
      const infoHeight = totalHeight - errorHeight - warnHeight;

      let y = height - padding.bottom;

      // Info (green)
      if (infoHeight > 0) {
        ctx.fillStyle = hoveredBar === i ? '#4ade80' : '#3fb950';
        ctx.fillRect(x, y - infoHeight, barWidth, infoHeight);
        y -= infoHeight;
      }

      // Warning (yellow)
      if (warnHeight > 0) {
        ctx.fillStyle = hoveredBar === i ? '#fbbf24' : '#d29922';
        ctx.fillRect(x, y - warnHeight, barWidth, warnHeight);
        y -= warnHeight;
      }

      // Error (red)
      if (errorHeight > 0) {
        ctx.fillStyle = hoveredBar === i ? '#f87171' : '#f85149';
        ctx.fillRect(x, y - errorHeight, barWidth, errorHeight);
      }

      // Anomaly highlight (pulsing red border)
      if (isAnomaly) {
        ctx.strokeStyle = '#f85149';
        ctx.lineWidth = 2;
        ctx.strokeRect(x - 1, height - padding.bottom - totalHeight - 1, barWidth + 2, totalHeight + 2);

        // Anomaly indicator triangle at top
        ctx.fillStyle = '#f85149';
        ctx.beginPath();
        ctx.moveTo(x + barWidth / 2, padding.top - 8);
        ctx.lineTo(x + barWidth / 2 - 5, padding.top - 2);
        ctx.lineTo(x + barWidth / 2 + 5, padding.top - 2);
        ctx.closePath();
        ctx.fill();
      }

      // Hover highlight
      if (hoveredBar === i && !isAnomaly) {
        ctx.strokeStyle = '#58a6ff';
        ctx.lineWidth = 2;
        ctx.strokeRect(x - 1, height - padding.bottom - totalHeight - 1, barWidth + 2, totalHeight + 2);
      }
    });

    // Draw selection overlay
    if (selectionRect) {
      ctx.fillStyle = 'rgba(88, 166, 255, 0.2)';
      ctx.strokeStyle = '#58a6ff';
      ctx.lineWidth = 1;
      ctx.fillRect(selectionRect.x, padding.top, selectionRect.width, chartHeight);
      ctx.strokeRect(selectionRect.x, padding.top, selectionRect.width, chartHeight);
    }

    // Draw time labels (X-axis)
    const labelCount = Math.min(6, $histogram.length);
    const labelStep = Math.floor($histogram.length / labelCount);
    ctx.fillStyle = '#6e7681';
    ctx.font = '10px SFMono-Regular, Consolas, monospace';
    ctx.textAlign = 'center';

    for (let i = 0; i < $histogram.length; i += labelStep) {
      const x = padding.left + i * (barWidth + gap) + barWidth / 2;
      const time = formatTime($histogram[i].time);
      ctx.fillText(time, x, height - 8);
    }

    // Draw baseline
    ctx.strokeStyle = '#30363d';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(padding.left, height - padding.bottom);
    ctx.lineTo(width - padding.right, height - padding.bottom);
    ctx.stroke();
  }

  function formatNumber(num) {
    if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
    if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
    return num.toString();
  }

  function formatTime(timestamp) {
    if (!timestamp) return '';
    const date = new Date(timestamp);
    return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
  }

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

  // RAF flag to prevent excessive redraws
  let rafPending = false;

  function scheduleRedraw() {
    if (!rafPending) {
      rafPending = true;
      requestAnimationFrame(() => {
        drawHistogram();
        rafPending = false;
      });
    }
  }

  function handleMouseMove(event) {
    const dims = getBarDimensions();
    if (!dims) return;

    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left;

    const { padding, barWidth, gap } = dims;
    const barIndex = Math.floor((x - padding.left) / (barWidth + gap));

    if (barIndex >= 0 && barIndex < $histogram.length && x >= padding.left) {
      hoveredBar = barIndex;
      const item = $histogram[barIndex];
      const prevItem = $previousHistogram[barIndex];

      // Calculate change percentage for this bucket
      let changePercent = null;
      if (prevItem && prevItem.count > 0) {
        changePercent = Math.round(((item.count - prevItem.count) / prevItem.count) * 100);
      }

      tooltip = {
        show: true,
        x: event.clientX - rect.left,
        y: event.clientY - rect.top - 10,
        data: item,
        prevData: prevItem,
        changePercent,
        isAnomaly: anomalies.includes(barIndex),
        avgCount
      };

      // Handle drag selection
      if (isDragging && dragStart !== null) {
        dragEnd = barIndex;
        const startX = padding.left + Math.min(dragStart, dragEnd) * (barWidth + gap);
        const endX = padding.left + (Math.max(dragStart, dragEnd) + 1) * (barWidth + gap) - gap;
        selectionRect = { x: startX, width: endX - startX };
      }
    } else {
      hoveredBar = -1;
      tooltip.show = false;
    }

    scheduleRedraw();
  }

  function handleMouseLeave() {
    hoveredBar = -1;
    tooltip.show = false;
    if (!isDragging) {
      selectionRect = null;
    }
    scheduleRedraw();
  }

  function handleMouseDown(event) {
    const dims = getBarDimensions();
    if (!dims) return;

    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const { padding, barWidth, gap } = dims;
    const barIndex = Math.floor((x - padding.left) / (barWidth + gap));

    if (barIndex >= 0 && barIndex < $histogram.length) {
      isDragging = true;
      dragStart = barIndex;
      dragEnd = barIndex;
    }
  }

  function handleMouseUp() {
    if (isDragging && dragStart !== null && dragEnd !== null) {
      const startIdx = Math.min(dragStart, dragEnd);
      const endIdx = Math.max(dragStart, dragEnd);
      const startTime = $histogram[startIdx]?.time;
      const endTimeRaw = $histogram[endIdx]?.time;

      if (startTime && endTimeRaw) {
        // Calculate end time based on interval
        const endDate = new Date(endTimeRaw);
        // Add interval duration to get actual end time
        // Detect interval from histogram bucket spacing
        if ($histogram.length >= 2) {
          const interval = new Date($histogram[1].time) - new Date($histogram[0].time);
          endDate.setTime(endDate.getTime() + interval);
        } else {
          // Default to 1 minute if single bucket
          endDate.setMinutes(endDate.getMinutes() + 1);
        }
        const endTime = endDate.toISOString();

        if (startIdx === endIdx) {
          // Single click - filter to this time bucket
          dispatch('filter', { start: startTime, end: endTime });
        } else {
          // Drag - zoom to range
          dispatch('zoom', { start: startTime, end: endTime });
        }
      }
    }

    isDragging = false;
    dragStart = null;
    dragEnd = null;
    selectionRect = null;
    scheduleRedraw();
  }

  function toggleComparison() {
    showComparison = !showComparison;
  }

  onMount(() => {
    const resizeObserver = new ResizeObserver(() => {
      if ($histogram.length > 0) drawHistogram();
    });
    resizeObserver.observe(container);
    return () => resizeObserver.disconnect();
  });
</script>

<div class="histogram-container" bind:this={container}>
  <div class="histogram-header">
    <div class="header-left">
      <Icon icon={barChartSolid} size={16} />
      <span class="histogram-title">Log Activity</span>
      <span class="time-range-badge">{$timeRange}</span>
      {#if anomalies.length > 0}
        <span class="anomaly-badge" title="Anomalies detected">
          <Icon icon={alertCircleSolid} size={12} />
          {anomalies.length}
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

  <div class="chart-wrapper">
    <canvas
      bind:this={canvas}
      on:mousemove={handleMouseMove}
      on:mouseleave={handleMouseLeave}
      on:mousedown={handleMouseDown}
      on:mouseup={handleMouseUp}
    ></canvas>

    {#if tooltip.show && tooltip.data}
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
    {/if}
  </div>

  <div class="legend">
    <div class="legend-item">
      <span class="legend-dot info"></span>
      <span>Info/Debug</span>
    </div>
    <div class="legend-item">
      <span class="legend-dot warning"></span>
      <span>Warning</span>
    </div>
    <div class="legend-item">
      <span class="legend-dot error"></span>
      <span>Error</span>
    </div>
    {#if anomalies.length > 0}
      <div class="legend-item anomaly">
        <span class="legend-dot anomaly"></span>
        <span>Anomaly</span>
      </div>
    {/if}
    <div class="legend-actions">
      <button
        class="compare-btn"
        class:active={showComparison}
        on:click={toggleComparison}
        title="Compare with previous period"
      >
        <Icon icon={columns} size={14} strokeWidth={2.5} />
        Compare
      </button>
      <span class="legend-hint">
        <Icon icon={textLines} size={12} strokeWidth={3} />
        Drag to zoom
      </span>
    </div>
  </div>
</div>

<style>
  .histogram-container {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 16px;
    margin-bottom: 16px;
  }

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
    font-family: 'SFMono-Regular', Consolas, monospace;
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

  .chart-wrapper {
    position: relative;
  }

  canvas {
    display: block;
    width: 100%;
    cursor: crosshair;
  }

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
    font-family: 'SFMono-Regular', Consolas, monospace;
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

  .legend {
    display: flex;
    align-items: center;
    gap: 16px;
    margin-top: 10px;
    padding-top: 10px;
    border-top: 1px solid #21262d;
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
    color: #8b949e;
  }

  .legend-item.anomaly {
    color: #f85149;
  }

  .legend-dot {
    width: 10px;
    height: 10px;
    border-radius: 2px;
  }

  .legend-dot.info { background: #3fb950; }
  .legend-dot.warning { background: #d29922; }
  .legend-dot.error { background: #f85149; }
  .legend-dot.anomaly {
    background: transparent;
    border: 2px solid #f85149;
  }

  .legend-actions {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .compare-btn {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 4px 8px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #8b949e;
    font-size: 11px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .compare-btn:hover {
    background: #30363d;
    color: #c9d1d9;
  }

  .compare-btn.active {
    background: rgba(88, 166, 255, 0.15);
    border-color: #58a6ff;
    color: #58a6ff;
  }

  .legend-hint {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
    color: #848d97;
  }

  .legend-hint :global(svg) {
    color: #484f58;
  }
</style>
