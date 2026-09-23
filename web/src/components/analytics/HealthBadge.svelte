<!--
  HealthBadge
  The weighted health score pill in the Analytics header, with a hover tooltip
  breaking the score down per factor (error rate, latency, cache, uptime,
  throughput). Purely derived from the metrics AnalyticsPage already polls.
-->
<script>
  let {
    /** Error rate as a fixed-2 percentage string, e.g. '0.42' */
    errorRate,
    /** P95 latency string from /metrics/json, e.g. '120ms' */
    p95Latency,
    /** P99 latency string from /metrics/json */
    p99Latency,
    /** Cache hit rate string, e.g. '37%' */
    cacheHitRate,
    /** Server uptime in seconds */
    uptimeSecs,
    /** Server uptime, human readable */
    uptimeHuman,
    /** Requests per second (string or number) */
    requestsPerSec,
  } = $props();

  // Before the runes migration these two statements referenced no reactive
  // value, so they ran once at mount and the badge never moved off its first
  // (empty-metrics) score. As deriveds they follow every poll.
  const healthFactors = $derived(getHealthFactors());
  const healthScore = $derived(calculateHealthScore(healthFactors));

  function calculateHealthScore(factors) {
    const totalWeight = factors.reduce((sum, f) => sum + f.weight, 0);
    const weightedScore = factors.reduce((sum, f) => sum + (f.score * f.weight), 0);
    return Math.round(weightedScore / totalWeight);
  }

  function getHealthFactors() {
    const factors = [];

    // 1. Error Rate (weight: 30) - most critical
    const errRate = parseFloat(errorRate) || 0;
    let errScore = 100;
    if (errRate > 10) errScore = 0;
    else if (errRate > 5) errScore = 30;
    else if (errRate > 1) errScore = 60;
    else if (errRate > 0) errScore = 85;
    factors.push({ name: 'Error Rate', score: errScore, weight: 30, value: `${errRate.toFixed(2)}%`, status: errScore >= 85 ? 'good' : errScore >= 60 ? 'warn' : 'bad' });

    // 2. P95 Latency (weight: 25)
    const p95Val = parseFloat(p95Latency) || 0;
    let p95Score = 100;
    if (p95Val > 1000) p95Score = 20;
    else if (p95Val > 500) p95Score = 50;
    else if (p95Val > 200) p95Score = 70;
    else if (p95Val > 100) p95Score = 85;
    factors.push({ name: 'P95 Latency', score: p95Score, weight: 25, value: p95Latency, status: p95Score >= 85 ? 'good' : p95Score >= 60 ? 'warn' : 'bad' });

    // 3. P99 Latency (weight: 15)
    const p99Val = parseFloat(p99Latency) || 0;
    let p99Score = 100;
    if (p99Val > 2000) p99Score = 20;
    else if (p99Val > 1000) p99Score = 50;
    else if (p99Val > 500) p99Score = 70;
    else if (p99Val > 200) p99Score = 85;
    factors.push({ name: 'P99 Latency', score: p99Score, weight: 15, value: p99Latency, status: p99Score >= 85 ? 'good' : p99Score >= 60 ? 'warn' : 'bad' });

    // 4. Cache Hit Rate (weight: 15)
    const cacheVal = parseFloat(cacheHitRate) || 0;
    let cacheScore = 100;
    if (cacheVal < 10) cacheScore = 30;
    else if (cacheVal < 30) cacheScore = 60;
    else if (cacheVal < 50) cacheScore = 80;
    factors.push({ name: 'Cache Hit Rate', score: cacheScore, weight: 15, value: cacheHitRate, status: cacheScore >= 80 ? 'good' : cacheScore >= 60 ? 'warn' : 'bad' });

    // 5. Uptime (weight: 10)
    const uptimeVal = uptimeSecs || 0;
    let uptimeScore = 100;
    if (uptimeVal < 60) uptimeScore = 50; // < 1 min - just started
    else if (uptimeVal < 300) uptimeScore = 70; // < 5 min
    else if (uptimeVal < 3600) uptimeScore = 90; // < 1 hour
    factors.push({ name: 'Uptime', score: uptimeScore, weight: 10, value: uptimeHuman, status: uptimeScore >= 90 ? 'good' : uptimeScore >= 70 ? 'warn' : 'bad' });

    // 6. Throughput (weight: 5) - bonus for handling load
    const rpsVal = parseFloat(requestsPerSec) || 0;
    let rpsScore = 70; // baseline
    if (rpsVal > 100) rpsScore = 100;
    else if (rpsVal > 10) rpsScore = 90;
    else if (rpsVal > 1) rpsScore = 80;
    factors.push({ name: 'Throughput', score: rpsScore, weight: 5, value: `${rpsVal}/s`, status: rpsScore >= 80 ? 'good' : rpsScore >= 70 ? 'warn' : 'bad' });

    return factors;
  }

  function getHealthColor(score) {
    if (score >= 90) return '#3fb950';
    if (score >= 70) return '#d29922';
    return '#f85149';
  }
</script>

<div class="health-badge-wrapper">
  <div class="health-badge" style="--health-color: {getHealthColor(healthScore)}">
    <span class="health-score">{healthScore}</span>
    <span class="health-label">Health</span>
  </div>
  <div class="health-tooltip">
    <div class="tooltip-header">Health Score Breakdown</div>
    {#each healthFactors as factor}
      <div class="tooltip-row">
        <span class="factor-name">{factor.name}</span>
        <span class="factor-value">{factor.value}</span>
        <span class="factor-score {factor.status}">{factor.score}</span>
        <span class="factor-weight">×{factor.weight}%</span>
      </div>
    {/each}
    <div class="tooltip-total">
      <span>Total Score</span>
      <span class="total-score" style="color: {getHealthColor(healthScore)}">{healthScore}</span>
    </div>
  </div>
</div>

<style>
  .health-badge-wrapper {
    position: relative;
  }

  .health-badge {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 12px;
    background: rgba(63, 185, 80, 0.1);
    border: 1px solid var(--health-color);
    border-radius: 20px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .health-badge:hover {
    background: rgba(63, 185, 80, 0.15);
    transform: scale(1.02);
  }

  .health-score {
    font-size: 0.875rem;
    font-weight: 700;
    color: var(--health-color);
  }

  .health-label {
    font-size: 0.6875rem;
    color: #8b949e;
    text-transform: uppercase;
  }

  .health-tooltip {
    position: absolute;
    top: calc(100% + 8px);
    left: 0;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 12px;
    min-width: 280px;
    z-index: 1000;
    opacity: 0;
    visibility: hidden;
    transform: translateY(-4px);
    transition: all 0.15s;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
  }

  .health-badge-wrapper:hover .health-tooltip {
    opacity: 1;
    visibility: visible;
    transform: translateY(0);
  }

  .tooltip-header {
    font-size: 0.75rem;
    font-weight: 600;
    color: #f0f6fc;
    margin-bottom: 10px;
    padding-bottom: 8px;
    border-bottom: 1px solid #21262d;
  }

  .tooltip-row {
    display: grid;
    grid-template-columns: 1fr auto auto auto;
    gap: 8px;
    align-items: center;
    padding: 4px 0;
    font-size: 0.75rem;
  }

  .factor-name {
    color: #8b949e;
  }

  .factor-value {
    color: #c9d1d9;
    font-family: var(--font-mono);
    text-align: right;
  }

  .factor-score {
    width: 28px;
    text-align: center;
    font-weight: 600;
    padding: 2px 4px;
    border-radius: 4px;
  }

  .factor-score.good {
    color: #3fb950;
    background: rgba(63, 185, 80, 0.1);
  }

  .factor-score.warn {
    color: #d29922;
    background: rgba(210, 153, 34, 0.1);
  }

  .factor-score.bad {
    color: #f85149;
    background: rgba(248, 81, 73, 0.1);
  }

  .factor-weight {
    color: #848d97;
    font-size: 0.625rem;
    width: 32px;
  }

  .tooltip-total {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-top: 10px;
    padding-top: 8px;
    border-top: 1px solid #21262d;
    font-weight: 600;
    color: #f0f6fc;
  }

  .total-score {
    font-size: 1.125rem;
    font-weight: 700;
  }
</style>
