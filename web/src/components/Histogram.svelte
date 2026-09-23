<!--
  Histogram
  Log-activity histogram above the log table. Derives the summary stats and
  anomalies from the histogram store, owns the previous-period comparison
  toggle, and composes the header, the interactive canvas and the legend.
-->
<script>
  import { untrack } from 'svelte';
  import { histogram, timeRange, previousHistogram, fetchPreviousHistogram } from '../stores/logs.js';
  import HistogramHeader from './histogram/HistogramHeader.svelte';
  import HistogramChart from './histogram/HistogramChart.svelte';
  import HistogramLegend from './histogram/HistogramLegend.svelte';

  /**
   * @type {{
   *   onfilter?: (e: { start: string, end: string }) => void,
   *   onzoom?: (e: { start: string, end: string }) => void,
   * }}
   */
  let { onfilter, onzoom } = $props();

  let container = $state(null);
  let showComparison = $state(false);

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

  const stats = $derived(calculateAllStats($histogram));
  const totalLogs = $derived(stats.total);
  const maxCount = $derived(stats.max);
  const avgCount = $derived(stats.avg);
  const errorCount = $derived(stats.errors);
  const warnCount = $derived(stats.warnings);
  const anomalies = $derived(stats.anomalies);

  // Previous period stats for comparison - single pass
  const prevTotalLogs = $derived($previousHistogram.reduce((sum, d) => sum + d.count, 0));
  const totalChangePercent = $derived(prevTotalLogs > 0
    ? Math.round(((totalLogs - prevTotalLogs) / prevTotalLogs) * 100)
    : null);

  // Fetch previous period when comparison is enabled
  $effect(() => {
    if (showComparison && $histogram.length > 0) untrack(() => fetchPreviousHistogram());
  });

  function toggleComparison() {
    showComparison = !showComparison;
  }
</script>

<div class="histogram-container" bind:this={container}>
  <HistogramHeader
    timeRange={$timeRange}
    anomalyCount={anomalies.length}
    {totalLogs}
    {totalChangePercent}
    {avgCount}
    {errorCount}
    {warnCount}
  />

  <HistogramChart
    {container}
    {showComparison}
    {maxCount}
    {avgCount}
    {anomalies}
    {onfilter}
    {onzoom}
  />

  <HistogramLegend
    hasAnomalies={anomalies.length > 0}
    {showComparison}
    ontogglecomparison={toggleComparison}
  />
</div>

<style>
  .histogram-container {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 16px;
    margin-bottom: 16px;
  }
</style>
