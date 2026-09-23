<!--
  HistogramLegend
  Footer of the log-activity histogram: the level colour key (plus the
  anomaly key when any bucket is anomalous), the Compare-with-previous-period
  toggle and the drag-to-zoom hint.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { columns, textLines } from '../ui/icons.js';

  let {
    /** At least one bucket is anomalous */
    hasAnomalies = false,
    /** The previous-period comparison is on */
    showComparison = false,
    /** () => void — Compare clicked */
    ontogglecomparison,
  } = $props();
</script>

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
  {#if hasAnomalies}
    <div class="legend-item anomaly">
      <span class="legend-dot anomaly"></span>
      <span>Anomaly</span>
    </div>
  {/if}
  <div class="legend-actions">
    <button
      class="compare-btn"
      class:active={showComparison}
      onclick={ontogglecomparison}
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

<style>
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
