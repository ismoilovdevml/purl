<script>
  import { onMount } from 'svelte';
  import { histogram } from '../stores/logs.js';

  let canvas;
  let container;

  $: if ($histogram.length > 0 && canvas) {
    drawHistogram();
  }

  function drawHistogram() {
    const ctx = canvas.getContext('2d');
    const rect = container.getBoundingClientRect();
    const width = rect.width;
    const height = 80;

    canvas.width = width * window.devicePixelRatio;
    canvas.height = height * window.devicePixelRatio;
    canvas.style.width = width + 'px';
    canvas.style.height = height + 'px';
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    // Clear
    ctx.clearRect(0, 0, width, height);

    if ($histogram.length === 0) return;

    const data = $histogram;
    const maxCount = Math.max(...data.map(d => d.count), 1);
    const barWidth = Math.max(2, (width - 20) / data.length - 1);
    const padding = 10;

    // Draw bars
    data.forEach((item, i) => {
      const x = padding + i * (barWidth + 1);
      const barHeight = (item.count / maxCount) * (height - 20);
      const y = height - barHeight - 10;

      // Gradient based on count
      const intensity = item.count / maxCount;
      const color = intensity > 0.7 ? '#f85149' :
                    intensity > 0.4 ? '#d29922' : '#3fb950';

      ctx.fillStyle = color;
      ctx.fillRect(x, y, barWidth, barHeight);
    });

    // Draw baseline
    ctx.strokeStyle = '#30363d';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(padding, height - 10);
    ctx.lineTo(width - padding, height - 10);
    ctx.stroke();
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
    <span class="histogram-title">Log volume over time</span>
    <span class="histogram-count">{$histogram.reduce((sum, d) => sum + d.count, 0).toLocaleString()} logs</span>
  </div>
  <canvas bind:this={canvas}></canvas>
</div>

<style>
  .histogram-container {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 12px;
    margin-bottom: 16px;
  }

  .histogram-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
  }

  .histogram-title {
    font-size: 12px;
    font-weight: 500;
    color: #8b949e;
    text-transform: uppercase;
  }

  .histogram-count {
    font-size: 12px;
    color: #58a6ff;
    font-family: 'SFMono-Regular', Consolas, monospace;
  }

  canvas {
    display: block;
    width: 100%;
  }
</style>
