<script>
  import { onMount, createEventDispatcher } from 'svelte';
  import { histogram, timeRange } from '../stores/logs.js';

  const dispatch = createEventDispatcher();

  let canvas;
  let container;
  let tooltip = { show: false, x: 0, y: 0, data: null };
  let hoveredBar = -1;
  let isDragging = false;
  let dragStart = null;
  let dragEnd = null;
  let selectionRect = null;

  // Stats
  $: totalLogs = $histogram.reduce((sum, d) => sum + d.count, 0);
  $: maxCount = Math.max(...$histogram.map(d => d.count), 1);
  $: avgCount = $histogram.length > 0 ? Math.round(totalLogs / $histogram.length) : 0;
  $: errorCount = $histogram.reduce((sum, d) => sum + (d.errors || 0), 0);
  $: warnCount = $histogram.reduce((sum, d) => sum + (d.warnings || 0), 0);

  $: if ($histogram.length > 0 && canvas) {
    drawHistogram();
  }

  function getBarDimensions() {
    const rect = container?.getBoundingClientRect();
    if (!rect) return null;
    const width = rect.width;
    const height = 100;
    const padding = { left: 50, right: 20, top: 10, bottom: 30 };
    const chartWidth = width - padding.left - padding.right;
    const chartHeight = height - padding.top - padding.bottom;
    const barWidth = Math.max(3, chartWidth / $histogram.length - 2);
    const gap = 2;
    return { width, height, padding, chartWidth, chartHeight, barWidth, gap };
  }

  function drawHistogram() {
    const ctx = canvas.getContext('2d');
    const dims = getBarDimensions();
    if (!dims) return;

    const { width, height, padding, chartHeight, barWidth, gap } = dims;

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
      const value = Math.round(maxCount - (maxCount / gridLines) * i);
      ctx.fillStyle = '#6e7681';
      ctx.font = '10px SFMono-Regular, Consolas, monospace';
      ctx.textAlign = 'right';
      ctx.fillText(formatNumber(value), padding.left - 8, y + 3);
    }

    // Draw bars with stacked levels
    $histogram.forEach((item, i) => {
      const x = padding.left + i * (barWidth + gap);
      const totalHeight = (item.count / maxCount) * chartHeight;

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

      // Hover highlight
      if (hoveredBar === i) {
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

  function handleMouseMove(event) {
    const dims = getBarDimensions();
    if (!dims) return;

    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left;

    // Find which bar is hovered
    const { padding, barWidth, gap } = dims;
    const barIndex = Math.floor((x - padding.left) / (barWidth + gap));

    if (barIndex >= 0 && barIndex < $histogram.length && x >= padding.left) {
      hoveredBar = barIndex;
      const item = $histogram[barIndex];
      tooltip = {
        show: true,
        x: event.clientX - rect.left,
        y: event.clientY - rect.top - 10,
        data: item
      };

      // Handle drag selection
      if (isDragging && dragStart !== null) {
        dragEnd = barIndex;
        const startX = padding.left + Math.min(dragStart, dragEnd) * (barWidth + gap);
        const endX = padding.left + (Math.max(dragStart, dragEnd) + 1) * (barWidth + gap) - gap;
        selectionRect = { x: startX, width: endX - startX };
        drawHistogram();
      }
    } else {
      hoveredBar = -1;
      tooltip.show = false;
    }

    drawHistogram();
  }

  function handleMouseLeave() {
    hoveredBar = -1;
    tooltip.show = false;
    if (!isDragging) {
      selectionRect = null;
    }
    drawHistogram();
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
    if (isDragging && dragStart !== null && dragEnd !== null && dragStart !== dragEnd) {
      const startIdx = Math.min(dragStart, dragEnd);
      const endIdx = Math.max(dragStart, dragEnd);
      const startTime = $histogram[startIdx]?.time;
      const endTime = $histogram[endIdx]?.time;

      if (startTime && endTime) {
        dispatch('zoom', { start: startTime, end: endTime });
      }
    }

    isDragging = false;
    dragStart = null;
    dragEnd = null;
    selectionRect = null;
    drawHistogram();
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
      <svg width="16" height="16" viewBox="0 0 16 16">
        <path fill="currentColor" d="M1 14h14v1H1v-1Zm1-3h2v3H2v-3Zm3-2h2v5H5V9Zm3-3h2v8H8V6Zm3-2h2v10h-2V4Zm3-3h1v13h-1V1Z"/>
      </svg>
      <span class="histogram-title">Log Volume Over Time</span>
      <span class="time-range-badge">{$timeRange}</span>
    </div>
    <div class="header-stats">
      <div class="stat">
        <span class="stat-value">{formatNumber(totalLogs)}</span>
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
      <div class="tooltip" style="left: {tooltip.x}px; top: {tooltip.y}px;">
        <div class="tooltip-time">{formatFullTime(tooltip.data.time)}</div>
        <div class="tooltip-stats">
          <div class="tooltip-row">
            <span class="tooltip-dot total"></span>
            <span>Total</span>
            <span class="tooltip-value">{tooltip.data.count.toLocaleString()}</span>
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
        </div>
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
    <div class="legend-hint">
      <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M1 4h10v1H1V4Zm2-2h6v1H3V2Zm-2 4h10v1H1V6Z"/></svg>
      Drag to zoom
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

  .header-left svg {
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
    font-size: 14px;
    font-weight: 600;
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #c9d1d9;
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
    color: #6e7681;
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
    min-width: 140px;
  }

  .tooltip-time {
    font-size: 11px;
    color: #8b949e;
    margin-bottom: 8px;
    padding-bottom: 6px;
    border-bottom: 1px solid #21262d;
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

  .tooltip-dot {
    width: 8px;
    height: 8px;
    border-radius: 2px;
  }

  .tooltip-dot.total { background: #58a6ff; }
  .tooltip-dot.error { background: #f85149; }
  .tooltip-dot.warning { background: #d29922; }
  .tooltip-dot.info { background: #3fb950; }

  .tooltip-value {
    margin-left: auto;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-weight: 500;
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

  .legend-dot {
    width: 10px;
    height: 10px;
    border-radius: 2px;
  }

  .legend-dot.info { background: #3fb950; }
  .legend-dot.warning { background: #d29922; }
  .legend-dot.error { background: #f85149; }

  .legend-hint {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
    color: #6e7681;
  }

  .legend-hint svg {
    color: #484f58;
  }
</style>
