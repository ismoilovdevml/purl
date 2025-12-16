<script>
  import { onMount, onDestroy } from 'svelte';

  export let percentiles = {};
  export let height = 100;

  let canvas;
  let container;
  let tooltip = { show: false, x: 0, y: 0, label: '', value: 0 };
  let hoveredBar = -1;

  const labels = ['p50', 'p75', 'p90', 'p95', 'p99'];
  const colors = ['#10b981', '#3b82f6', '#8b5cf6', '#f59e0b', '#ef4444'];

  $: values = labels.map(l => percentiles[`${l}_ms`] || 0);
  $: maxValue = Math.max(...values, 1);

  $: if (canvas && container) {
    drawChart();
  }

  function drawChart() {
    const ctx = canvas.getContext('2d');
    const rect = container?.getBoundingClientRect();
    if (!rect) return;

    const width = rect.width;
    const padding = { left: 45, right: 15, top: 10, bottom: 25 };
    const chartWidth = width - padding.left - padding.right;
    const chartHeight = height - padding.top - padding.bottom;

    canvas.width = width * window.devicePixelRatio;
    canvas.height = height * window.devicePixelRatio;
    canvas.style.width = width + 'px';
    canvas.style.height = height + 'px';
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    ctx.clearRect(0, 0, width, height);

    const barCount = labels.length;
    const gap = 8;
    const barWidth = (chartWidth - (barCount - 1) * gap) / barCount;

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

      const value = Math.round(maxValue - (maxValue / gridLines) * i);
      ctx.fillStyle = '#6e7681';
      ctx.font = '9px system-ui, sans-serif';
      ctx.textAlign = 'right';
      ctx.fillText(value + 'ms', padding.left - 5, y + 3);
    }

    // Draw bars
    labels.forEach((label, i) => {
      const value = values[i];
      const x = padding.left + i * (barWidth + gap);
      const barHeight = (value / maxValue) * chartHeight;
      const y = height - padding.bottom - barHeight;

      // Bar with gradient
      const gradient = ctx.createLinearGradient(x, y, x, height - padding.bottom);
      gradient.addColorStop(0, colors[i]);
      gradient.addColorStop(1, adjustColor(colors[i], -30));

      ctx.fillStyle = hoveredBar === i ? adjustColor(colors[i], 20) : gradient;
      ctx.beginPath();
      ctx.roundRect(x, y, barWidth, barHeight, [4, 4, 0, 0]);
      ctx.fill();

      // Label
      ctx.fillStyle = hoveredBar === i ? '#f0f6fc' : '#8b949e';
      ctx.font = '10px system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText(label.toUpperCase(), x + barWidth / 2, height - 6);
    });
  }

  function adjustColor(hex, amount) {
    const num = parseInt(hex.slice(1), 16);
    const r = Math.min(255, Math.max(0, (num >> 16) + amount));
    const g = Math.min(255, Math.max(0, ((num >> 8) & 0x00FF) + amount));
    const b = Math.min(255, Math.max(0, (num & 0x0000FF) + amount));
    return `rgb(${r}, ${g}, ${b})`;
  }

  function handleMouseMove(e) {
    const rect = container?.getBoundingClientRect();
    if (!rect) return;

    const width = rect.width;
    const padding = { left: 45, right: 15 };
    const chartWidth = width - padding.left - padding.right;
    const gap = 8;
    const barWidth = (chartWidth - (labels.length - 1) * gap) / labels.length;

    const x = e.clientX - rect.left;
    const chartX = x - padding.left;
    const barIndex = Math.floor(chartX / (barWidth + gap));

    if (barIndex >= 0 && barIndex < labels.length && chartX >= 0) {
      hoveredBar = barIndex;
      tooltip = {
        show: true,
        x: e.clientX,
        y: e.clientY,
        label: labels[barIndex].toUpperCase(),
        value: values[barIndex]
      };
      drawChart();
    } else {
      handleMouseLeave();
    }
  }

  function handleMouseLeave() {
    hoveredBar = -1;
    tooltip = { show: false, x: 0, y: 0, label: '', value: 0 };
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

  {#if tooltip.show}
    <div class="tooltip" style="left: {tooltip.x + 10}px; top: {tooltip.y - 30}px;">
      <strong>{tooltip.label}</strong>: {tooltip.value.toFixed(2)}ms
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
    padding: 6px 10px;
    font-size: 11px;
    color: #c9d1d9;
    pointer-events: none;
    z-index: 1000;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  }
</style>
