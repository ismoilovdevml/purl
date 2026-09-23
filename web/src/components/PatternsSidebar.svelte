<script>
  import { onMount, untrack } from 'svelte';
  import { patterns, patternsLoading, patternsError, fetchPatterns, fetchPatternLogs, logs, timeRange, query, total } from '../stores/logs.js';
  import LoadingSpinner from './ui/LoadingSpinner.svelte';
  import EmptyState from './ui/EmptyState.svelte';
  import Icon from './ui/Icon.svelte';
  import PatternItem from './patterns/PatternItem.svelte';
  import { caretRight, refresh, layers } from './ui/icons.js';
  import { api } from '../utils/api.js';
  import { formatCount } from '../utils/format.js';

  let selectedPattern = $state(null);
  let patternLogsLoading = $state(false);
  let expanded = $state(true);

  let patternStats = $state(null);

  // Track previous time range to avoid cascade fetches
  let previousTimeRange = null;

  async function fetchPatternStats() {
    try {
      patternStats = await api.get('/patterns/stats');
    } catch {
      // Stats are non-critical, silently ignore
    }
  }

  onMount(() => {
    previousTimeRange = $timeRange;
    fetchPatterns();
    fetchPatternStats();
  });

  // Refetch when time range changes - only if actually changed
  // `previousTimeRange` is a plain let, so `$timeRange` is the only dependency;
  // the fetches run untracked so store reads inside them cannot re-arm it.
  $effect(() => {
    const range = $timeRange;
    if (!range || previousTimeRange === null || previousTimeRange === range) return;
    previousTimeRange = range;
    untrack(() => {
      fetchPatterns();
      fetchPatternStats();
      selectedPattern = null;
    });
  });

  async function selectPattern(pattern) {
    if (selectedPattern?.pattern_hash === pattern.pattern_hash) {
      selectedPattern = null;
      return;
    }

    selectedPattern = pattern;
    patternLogsLoading = true;

    const result = await fetchPatternLogs(pattern.pattern_hash);
    patternLogsLoading = false;

    if (result && result.hits) {
      // Clear query and update main logs view with pattern logs
      query.set(`pattern:${pattern.pattern_hash}`);
      // Create new array to trigger reactivity
      const logsWithIds = result.hits.map((log, index) => ({
        ...log,
        id: log.id || `${log.timestamp}-${index}`
      }));
      logs.set(logsWithIds);
      total.set(result.total || logsWithIds.length);
    }
  }

  function toggleExpand() {
    expanded = !expanded;
  }
</script>

<div class="patterns-sidebar" class:collapsed={!expanded}>
  <div class="sidebar-header">
    <button
      class="expand-btn"
      onclick={toggleExpand}
      title={expanded ? 'Collapse' : 'Expand'}
      aria-label={expanded ? 'Collapse patterns sidebar' : 'Expand patterns sidebar'}
      aria-expanded={expanded}
    >
      <Icon icon={caretRight} size={12} class={expanded ? '' : 'rotated'} />
    </button>
    <h3>Patterns</h3>
    <button
      class="refresh-btn"
      onclick={fetchPatterns}
      disabled={$patternsLoading}
      title="Refresh patterns"
      aria-label="Refresh patterns"
    >
      <Icon icon={refresh} size={14} strokeWidth={2.5} spin={$patternsLoading} />
    </button>
  </div>

  {#if expanded}
    <div class="patterns-content">
      {#if $patternsError}
        <div class="error-state">
          <span>{$patternsError}</span>
          <button class="retry-btn" onclick={fetchPatterns}>Retry</button>
        </div>
      {:else if $patternsLoading && $patterns.length === 0}
        <div class="loading-state">
          <LoadingSpinner size="sm" label="Loading patterns..." />
        </div>
      {:else if $patterns.length === 0}
        <EmptyState icon={layers} title="No patterns found" size="sm">
          Patterns appear once Purl has grouped similar log lines in this time range.
        </EmptyState>
      {:else}
        {#if patternStats && patternStats.total_patterns != null}
          <div class="pattern-stats">
            <div class="stat-item">
              <span class="stat-value">{formatCount(patternStats.total_patterns)}</span>
              <span class="stat-label">patterns</span>
            </div>
            {#if patternStats.pattern_coverage != null}
              <div class="stat-item">
                <span class="stat-value">{patternStats.pattern_coverage}%</span>
                <span class="stat-label">coverage</span>
              </div>
            {/if}
          </div>
        {/if}
        <div class="patterns-list">
          {#each $patterns as pattern}
            <PatternItem
              {pattern}
              countLabel={formatCount(pattern.count)}
              selected={selectedPattern?.pattern_hash === pattern.pattern_hash}
              onselect={() => selectPattern(pattern)}
            />
          {/each}
        </div>
      {/if}

      {#if selectedPattern && patternLogsLoading}
        <div class="pattern-detail">
          <LoadingSpinner size="sm" label="Loading pattern logs..." />
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .patterns-sidebar {
    width: 320px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    display: flex;
    flex-direction: column;
    max-height: calc(100vh - 280px);
    overflow: hidden;
    transition: width 0.2s;
  }

  .patterns-sidebar.collapsed {
    width: 40px;
  }

  .sidebar-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 12px;
    background: #21262d;
    border-bottom: 1px solid #30363d;
  }

  .sidebar-header h3 {
    flex: 1;
    margin: 0;
    font-size: 13px;
    font-weight: 600;
    color: #c9d1d9;
  }

  .collapsed .sidebar-header h3,
  .collapsed .refresh-btn {
    display: none;
  }

  .expand-btn,
  .refresh-btn {
    background: none;
    border: none;
    color: #8b949e;
    cursor: pointer;
    padding: 4px;
    border-radius: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .expand-btn:hover,
  .refresh-btn:hover {
    background: #30363d;
    color: #c9d1d9;
  }

  /* :global — Icon renders its SVG inside its own component scope. */
  .expand-btn :global(svg) {
    transition: transform 0.2s;
  }

  .expand-btn :global(svg.rotated) {
    transform: rotate(180deg);
  }

  .patterns-content {
    flex: 1;
    overflow-y: auto;
  }

  .pattern-stats {
    display: flex;
    align-items: center;
    justify-content: space-around;
    padding: 8px 12px;
    background: #1c2128;
    border-bottom: 1px solid #30363d;
  }

  .stat-item {
    display: flex;
    align-items: baseline;
    gap: 4px;
  }

  .stat-value {
    font-size: 14px;
    font-weight: 700;
    color: #58a6ff;
  }

  .stat-label {
    font-size: 11px;
    color: #8b949e;
  }

  .loading-state,
  .error-state {
    padding: 20px;
    text-align: center;
    color: #8b949e;
    font-size: 13px;
  }

  .error-state {
    color: #f85149;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
  }

  .retry-btn {
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 4px;
    padding: 4px 12px;
    font-size: 12px;
    color: var(--text-primary);
    cursor: pointer;
  }

  .retry-btn:hover {
    background: var(--border-color);
  }

  .patterns-list {
    display: flex;
    flex-direction: column;
  }

  .pattern-detail {
    padding: 12px;
    background: #0d1117;
    border-top: 1px solid #30363d;
  }
</style>
