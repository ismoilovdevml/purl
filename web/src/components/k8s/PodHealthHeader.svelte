<!--
  PodHealthHeader
  Title row of the K8s Pod Health page: the unhealthy-pod count badge, the
  lookback range selector, the auto/manual refresh toggle and refresh-now.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { refresh } from '../ui/icons.js';

  let {
    /** Show the "N unhealthy" badge (hidden while loading, on error, or with no data) */
    showBadge = false,
    /** Number of unhealthy pods */
    totalUnhealthy = 0,
    /** Selected lookback window in hours */
    selectedHours,
    /** Auto-refresh every 30s is on */
    autoRefresh = true,
    /** A pod-health fetch is in flight */
    loading = false,
    /** (hours) => void — a range button was clicked */
    ontimerange,
    /** () => void — the Auto/Manual toggle was clicked */
    ontoggleautorefresh,
    /** () => void — refresh-now was clicked */
    onrefresh,
  } = $props();

  // Time range options
  const timeRanges = [
    { label: '1h', hours: 1 },
    { label: '6h', hours: 6 },
    { label: '24h', hours: 24 },
    { label: '7d', hours: 168 },
  ];
</script>

<header class="page-header">
  <div class="header-left">
    <h1>K8s Pod Health</h1>
    {#if showBadge}
      <span class="pod-count-badge" class:healthy={totalUnhealthy === 0} class:unhealthy={totalUnhealthy > 0}>
        {totalUnhealthy} unhealthy
      </span>
    {/if}
  </div>
  <div class="header-right">
    <!-- Time range selector -->
    <div class="time-range">
      {#each timeRanges as range}
        <button
          class="range-btn"
          class:active={selectedHours === range.hours}
          onclick={() => ontimerange(range.hours)}
        >
          {range.label}
        </button>
      {/each}
    </div>

    <!-- Auto-refresh toggle -->
    <button class="auto-refresh-btn" class:active={autoRefresh} onclick={ontoggleautorefresh} title="Auto-refresh every 30s">
      <Icon icon={refresh} size={14} />
      <span>{autoRefresh ? 'Auto' : 'Manual'}</span>
    </button>

    <!-- Manual refresh -->
    <button
      class="refresh-btn"
      onclick={onrefresh}
      disabled={loading}
      title="Refresh now"
      aria-label="Refresh pod health"
    >
      <Icon icon={refresh} size={14} spin={loading} />
    </button>
  </div>
</header>

<style>
  /* Header */
  .page-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .header-left h1 {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .pod-count-badge {
    font-size: 0.75rem;
    font-weight: 600;
    padding: 3px 10px;
    border-radius: 12px;
  }

  .pod-count-badge.healthy {
    background: rgba(63, 185, 80, 0.15);
    color: #3fb950;
    border: 1px solid rgba(63, 185, 80, 0.3);
  }

  .pod-count-badge.unhealthy {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
    border: 1px solid rgba(248, 81, 73, 0.3);
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* Time range selector */
  .time-range {
    display: flex;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    overflow: hidden;
  }

  .range-btn {
    padding: 6px 12px;
    background: none;
    border: none;
    border-right: 1px solid #30363d;
    color: #8b949e;
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .range-btn:last-child {
    border-right: none;
  }

  .range-btn:hover {
    color: #c9d1d9;
    background: #21262d;
  }

  .range-btn.active {
    color: #58a6ff;
    background: rgba(88, 166, 255, 0.1);
  }

  /* Auto-refresh toggle */
  .auto-refresh-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #8b949e;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .auto-refresh-btn:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .auto-refresh-btn.active {
    color: #3fb950;
    border-color: rgba(63, 185, 80, 0.3);
  }

  /* Refresh button */
  .refresh-btn {
    padding: 6px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s;
  }

  .refresh-btn:hover {
    background: #30363d;
  }

  .refresh-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  @media (max-width: 768px) {
    .page-header {
      flex-direction: column;
      align-items: flex-start;
      gap: 12px;
    }

    .header-right {
      width: 100%;
      flex-wrap: wrap;
    }
  }
</style>
