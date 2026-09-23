<!--
  TraceTimeline
  One bar per service across the trace's time span, positioned from the
  per-service windows TracesPage's buildTimeline() produced.
-->
<script>
  import { formatDuration } from '../../utils/format.js';

  /**
   * @type {{
   *   timeline: { durationMs: number, spans: Array<{ service: string, startMs: number,
   *               durationMs: number, logCount: number, errorCount: number }> },
   *   serviceColor: (service: string) => string,
   * }}
   */
  let { timeline, serviceColor } = $props();

  const durationMs = $derived(timeline.durationMs);

  /**
   * One row per service, each holding the single bar the API gives us.
   *
   * A whole-trace duration of 0 (every service logged inside the same
   * millisecond) is a real case, not an error: the bars then span the full
   * track rather than the section disappearing.
   */
  const rows = $derived(timeline.spans.map(span => ({
    service: span.service,
    color: serviceColor(span.service),
    logCount: span.logCount,
    errorCount: span.errorCount,
    durationMs: span.durationMs,
    startMs: span.startMs,
    leftPct: durationMs > 0 ? (span.startMs / durationMs) * 100 : 0,
    widthPct: durationMs > 0 ? Math.max((span.durationMs / durationMs) * 100, 0.5) : 100,
  })));

  const plural = (n, word) => `${n} ${word}${n !== 1 ? 's' : ''}`;

  function spanTitle(row) {
    const range = `${formatDuration(row.startMs)} - ${formatDuration(row.startMs + row.durationMs)}`;
    const errors = row.errorCount > 0 ? `, ${plural(row.errorCount, 'error')}` : '';
    return `${row.service}: ${formatDuration(row.durationMs)} (${range}), ${plural(row.logCount, 'log')}${errors}`;
  }
</script>

<div class="timeline-section">
  <div class="section-header">
    <h2>Timeline</h2>
    <span class="section-meta">{formatDuration(durationMs)} total</span>
  </div>
  <div class="timeline-container">
    <!-- Time axis -->
    <div class="timeline-axis">
      <span class="axis-label">0ms</span>
      <span class="axis-label">{formatDuration(durationMs * 0.25)}</span>
      <span class="axis-label">{formatDuration(durationMs * 0.5)}</span>
      <span class="axis-label">{formatDuration(durationMs * 0.75)}</span>
      <span class="axis-label">{formatDuration(durationMs)}</span>
    </div>

    <!-- Service rows -->
    {#each rows as row, i (i)}
      <div class="timeline-row">
        <div class="timeline-service">
          <span class="service-dot" style="background: {row.color}"></span>
          <span class="service-name">{row.service}</span>
        </div>
        <div class="timeline-track">
          <!-- Grid lines -->
          <div class="grid-line" style="left: 25%"></div>
          <div class="grid-line" style="left: 50%"></div>
          <div class="grid-line" style="left: 75%"></div>

          <div
            class="timeline-span"
            style="left: {row.leftPct}%; width: {row.widthPct}%; background: {row.color};"
            title={spanTitle(row)}
          >
            {#if row.widthPct > 8}
              <span class="span-label">{plural(row.logCount, 'log')}</span>
            {/if}
          </div>
        </div>
      </div>
    {/each}
  </div>
</div>

<style>
  .timeline-section {
    margin-bottom: 20px;
    flex-shrink: 0;
  }

  .section-header {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
  }

  h2 {
    font-size: 0.75rem;
    font-weight: 600;
    color: #8b949e;
    margin: 0;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .section-meta {
    font-size: 0.6875rem;
    color: #848d97;
  }

  .timeline-container {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 12px 16px;
    overflow-x: auto;
  }

  .timeline-axis {
    display: flex;
    justify-content: space-between;
    padding-left: 140px;
    margin-bottom: 8px;
    border-bottom: 1px solid #21262d;
    padding-bottom: 6px;
  }

  .axis-label {
    font-size: 0.625rem;
    color: #848d97;
    font-family: var(--font-mono);
  }

  .timeline-row {
    display: flex;
    align-items: center;
    height: 32px;
    gap: 0;
  }

  .timeline-row:not(:last-child) {
    border-bottom: 1px solid #21262d;
  }

  .timeline-service {
    width: 140px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 8px;
    padding-right: 12px;
  }

  .service-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .service-name {
    font-size: 0.75rem;
    color: #c9d1d9;
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .timeline-track {
    flex: 1;
    position: relative;
    height: 100%;
    min-width: 400px;
  }

  .grid-line {
    position: absolute;
    top: 0;
    bottom: 0;
    width: 1px;
    background: #21262d;
  }

  .timeline-span {
    position: absolute;
    top: 6px;
    height: 20px;
    border-radius: 3px;
    opacity: 0.85;
    cursor: pointer;
    transition: opacity 0.15s, transform 0.15s;
    display: flex;
    align-items: center;
    overflow: hidden;
    min-width: 2px;
  }

  .timeline-span:hover {
    opacity: 1;
    transform: scaleY(1.15);
    z-index: 2;
  }

  .span-label {
    font-size: 0.625rem;
    color: #fff;
    padding: 0 4px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-weight: 500;
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
  }

  @media (max-width: 900px) {
    .timeline-service {
      width: 100px;
    }
  }

  @media (max-width: 640px) {
    .timeline-axis {
      padding-left: 80px;
    }

    .timeline-service {
      width: 80px;
    }

    .service-name {
      font-size: 0.6875rem;
    }
  }
</style>
