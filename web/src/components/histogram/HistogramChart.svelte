<!--
  HistogramChart
  The interactive canvas of the log-activity histogram: stacked level bars,
  anomaly markers, the dotted previous-period line, hover tooltip, and
  click-to-filter / drag-to-zoom selection. Histogram owns the data-derived
  stats and the comparison toggle; this component owns everything the
  pointer touches.
-->
<script>
  import { untrack } from 'svelte';
  import { histogram, previousHistogram } from '../../stores/logs.js';
  import HistogramTooltip from './HistogramTooltip.svelte';
  import { formatHistogramCount as formatNumber, histogramLayout } from '../../utils/histogram.js';

  let {
    /** The .histogram-container element; its width sizes the chart */
    container,
    /** Draw the previous period as a dotted line */
    showComparison = false,
    /** Largest bucket count in the current period */
    maxCount = 1,
    /** Average logs per bucket (shown in the anomaly callout) */
    avgCount = 0,
    /** Indexes of anomalous buckets */
    anomalies = [],
    /** ({ start, end }) => void — single bucket clicked */
    onfilter,
    /** ({ start, end }) => void — range dragged */
    onzoom,
  } = $props();

  // Canvas text cannot use CSS custom properties, so the axis colour is pinned
  // here. It must stay >= 4.5:1 against .histogram-container's #161b22 because
  // the labels render at 10px, far below the WCAG large-text threshold.
  // #848d97 = 5.14:1 (passes AA); the previous #6e7681 was 3.77:1 (failed).
  const AXIS_LABEL_COLOR = '#848d97';

  // Same problem for the axis FONT, but here the token can be resolved at
  // runtime instead of duplicated: canvas takes a plain font shorthand, so read
  // --font-mono off the document once and reuse it. Hardcoding a second stack
  // is what made these labels render in a different face than every other
  // monospace surface in the app.
  let axisFontCache = '';
  function axisFont() {
    if (!axisFontCache) {
      const stack = getComputedStyle(document.documentElement)
        .getPropertyValue('--font-mono')
        .trim();
      axisFontCache = `10px ${stack || 'monospace'}`;
    }
    return axisFontCache;
  }

  let canvas = $state(null);
  let tooltip = $state({ show: false, x: 0, y: 0, data: null, prevData: null, changePercent: null });
  // Plain lets: hover/drag state only feeds the canvas, which is redrawn
  // imperatively, so none of it needs to be reactive.
  let hoveredBar = -1;
  let isDragging = false;
  let dragStart = null;
  let dragEnd = null;
  let selectionRect = null;

  // Redraw when the data or the canvas changes — and only then: the draw runs
  // untracked so the comparison toggle and previous-period data (read inside
  // it) do not add dependencies the pre-runes reactive statement never had.
  $effect(() => {
    if ($histogram.length > 0 && canvas) untrack(drawHistogram);
  });

  // Redraw on resize. Histogram binds `container`, so observe it once it
  // exists (the pre-split onMount observed the same element).
  $effect(() => {
    if (!container) return;
    const resizeObserver = new ResizeObserver(() => {
      if ($histogram.length > 0) drawHistogram();
    });
    resizeObserver.observe(container);
    return () => resizeObserver.disconnect();
  });

  function getBarDimensions() {
    const rect = container?.getBoundingClientRect();
    if (!rect) return null;
    return histogramLayout(rect.width, $histogram.length);
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
      ctx.fillStyle = AXIS_LABEL_COLOR;
      ctx.font = axisFont();
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
    ctx.fillStyle = AXIS_LABEL_COLOR;
    ctx.font = axisFont();
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

  function formatTime(timestamp) {
    if (!timestamp) return '';
    const date = new Date(timestamp);
    return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
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
          onfilter?.({ start: startTime, end: endTime });
        } else {
          // Drag - zoom to range
          onzoom?.({ start: startTime, end: endTime });
        }
      }
    }

    isDragging = false;
    dragStart = null;
    dragEnd = null;
    selectionRect = null;
    scheduleRedraw();
  }
</script>

<div class="chart-wrapper">
  <canvas
    bind:this={canvas}
    onmousemove={handleMouseMove}
    onmouseleave={handleMouseLeave}
    onmousedown={handleMouseDown}
    onmouseup={handleMouseUp}
  ></canvas>

  {#if tooltip.show && tooltip.data}
    <HistogramTooltip {tooltip} {showComparison} />
  {/if}
</div>

<style>
  .chart-wrapper {
    position: relative;
  }

  canvas {
    display: block;
    width: 100%;
    cursor: crosshair;
  }
</style>
