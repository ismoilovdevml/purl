<script>
  import { onMount, onDestroy } from 'svelte';

  export let data = [];
  export let height = 120;

  let canvas;
  let container;
  let tooltip = { show: false, x: 0, y: 0, data: null };
  let hoveredBar = -1;

  $: maxCount = Math.max(...data.map(d => d.requests || 0), 1);

  $: if (data.length > 0 && canvas) {
    drawChart();
  }

  function getBarDimensions() {
    const rect = container?.getBoundingClientRect();
    if (!rect) return null;
    const width = rect.width;
    const padding = { left: 40, right: 10, top: 10, bottom: 25 };
    const chartWidth = width - padding.left - padding.right;
    const chartHeight = height - padding.top - padding.bottom;
    const barCount = data.length || 1;
    const gap = 1;
    const barWidth = Math.max(2, (chartWidth - (barCount - 1) * gap) / barCount);
    return { width, height, padding, chartWidth, chartHeight, barWidth, gap };
  }

  function drawChart() {
    const ctx = canvas.getContext('2d');
    const dims = getBarDimensions();
    if (!dims) return;

    const { width, padding, chartHeight, barWidth, gap } = dims;

    canvas.width = width * window.devicePixelRatio;
    canvas.height = height * window.devicePixelRatio;
    canvas.style.width = width + 'px';
    canvas.style.height = height + 'px';
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    ctx.clearRect(0, 0, width, height);

    if (data.length === 0) {
      ctx.fillStyle = '#6e7681';
      ctx.font = '12px system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('No data', width / 2, height / 2);
      return;
    }

    // Draw grid lines
    ctx.strokeStyle = 'rgba(48, 54, 61, 0.6)';
    ctx.lineWidth = 1;
    const gridLines = 3;
    for (let i = 0; i <= gridLines; i++) {
      const y = padding.top + (chartHeight / gridLines) * i;
      ctx.beginPath();
      ctx.moveTo(padding.left, y);
      ctx.lineTo(width - padding.right, y);
      ctx.stroke();

      const value = Math.round(maxCount - (maxCount / gridLines) * i);
      ctx.fillStyle = '#6e7681';
      ctx.font = '9px system-ui, sans-serif';
      ctx.textAlign = 'right';
      ctx.fillText(formatNumber(value), padding.left - 5, y + 3);
    }

    // Draw bars
    data.forEach((item, i) => {
      const x = padding.left + i * (barWidth + gap);
      const totalHeight = ((item.requests || 0) / maxCount) * chartHeight;
      const errorHeight = item.errors ? (item.errors / (item.requests || 1)) * totalHeight : 0;
      const requestHeight = totalHeight - errorHeight;

      let y = height - padding.bottom;

      // Requests (blue)
      if (requestHeight > 0) {
        ctx.fillStyle = hoveredBar === i ? '#60a5fa' : '#3b82f6';
        ctx.fillRect(x, y - requestHeight, barWidth, requestHeight);
        y -= requestHeight;
      }

      // Errors (red) - stacked on top
      if (errorHeight > 0) {
        ctx.fillStyle = hoveredBar === i ? '#f87171' : '#ef4444';
        ctx.fillRect(x, y - errorHeight, barWidth, errorHeight);
      }
    });

    // X-axis labels (time)
    if (data.length > 0) {
      ctx.fillStyle = '#6e7681';
      ctx.font = '9px system-ui, sans-serif';
      ctx.textAlign = 'center';

      const labelCount = Math.min(5, data.length);
      const step = Math.floor(data.length / labelCount);

      for (let i = 0; i < data.length; i += step) {
        const item = data[i];
        const x = padding.left + i * (barWidth + gap) + barWidth / 2;
        const time = new Date(item.time);
        const label = time.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        ctx.fillText(label, x, height - 5);
      }
    }
  }

  function formatNumber(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n.toString();
  }

  function handleMouseMove(e) {
    const dims = getBarDimensions();
    if (!dims || data.length === 0) return;

    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const { padding, barWidth, gap } = dims;

    const chartX = x - padding.left;
    const barIndex = Math.floor(chartX / (barWidth + gap));

    if (barIndex >= 0 && barIndex < data.length) {
      hoveredBar = barIndex;
      tooltip = {
        show: true,
        x: e.clientX,
        y: e.clientY,
        data: data[barIndex]
      };
      drawChart();
    } else {
      handleMouseLeave();
    }
  }

  function handleMouseLeave() {
    hoveredBar = -1;
    tooltip = { show: false, x: 0, y: 0, data: null };
    if (canvas) drawChart();
  }

  let resizeObserver;

  onMount(() => {
    drawChart();
    resizeObserver = new ResizeObserver(() => drawChart());
    if (container) resizeObserver.observe(container);
  });

  onDestroy(() => {
    if (resizeObserver) resizeObserver.disconnect();
  });
</script>

<div class="chart-container" bind:this={container}>
  <canvas
    bind:this={canvas}
    on:mousemove={handleMouseMove}
    on:mouseleave={handleMouseLeave}
  ></canvas>

  {#if tooltip.show && tooltip.data}
    <div class="tooltip" style="left: {tooltip.x + 10}px; top: {tooltip.y - 40}px;">
      <div class="tooltip-time">{new Date(tooltip.data.time).toLocaleString()}</div>
      <div class="tooltip-row">
        <span class="dot blue"></span>
        Requests: {formatNumber(tooltip.data.requests || 0)}
      </div>
      <div class="tooltip-row">
        <span class="dot red"></span>
        Errors: {formatNumber(tooltip.data.errors || 0)}
      </div>
    </div>
  {/if}
</div>

<style>
  .chart-container {
    position: relative;
    width: 100%;
  }

  canvas {
    display: block;
    width: 100%;
    cursor: crosshair;
  }

  .tooltip {
    position: fixed;
    background: rgba(13, 17, 23, 0.95);
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 8px 10px;
    font-size: 11px;
    color: #c9d1d9;
    pointer-events: none;
    z-index: 1000;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  }

  .tooltip-time {
    font-weight: 500;
    margin-bottom: 4px;
    color: #f0f6fc;
  }

  .tooltip-row {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 2px;
  }

  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
  }

  .dot.blue {
    background: #3b82f6;
  }

  .dot.red {
    background: #ef4444;
  }
</style>
