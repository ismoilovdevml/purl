<script>
  import { onMount } from 'svelte';
  import { patterns, patternsLoading, patternsError, fetchPatterns, fetchPatternLogs, highlightPattern, logs, timeRange, query, total } from '../stores/logs.js';
  import { getLevelColor } from '../utils/colors.js';

  let selectedPattern = null;
  let patternLogs = null;
  let patternLogsLoading = false;
  let expanded = true;

  onMount(() => {
    fetchPatterns();
  });

  // Refetch when time range changes
  $: if ($timeRange) {
    fetchPatterns();
    selectedPattern = null;
    patternLogs = null;
  }

  async function selectPattern(pattern) {
    if (selectedPattern?.pattern_hash === pattern.pattern_hash) {
      selectedPattern = null;
      patternLogs = null;
      return;
    }

    selectedPattern = pattern;
    patternLogsLoading = true;

    const result = await fetchPatternLogs(pattern.pattern_hash);
    patternLogsLoading = false;

    if (result && result.hits) {
      patternLogs = result.hits;
      // Clear query and update main logs view with pattern logs
      query.set(`pattern:${pattern.pattern_hash}`);
      // Create new array to trigger reactivity
      const logsWithIds = patternLogs.map((log, index) => ({
        ...log,
        id: log.id || `${log.timestamp}-${index}`
      }));
      console.log('Setting logs:', logsWithIds.length, logsWithIds);
      logs.set(logsWithIds);
      total.set(result.total || logsWithIds.length);
    } else {
      console.log('No result or hits:', result);
    }
  }

  function formatCount(count) {
    if (count >= 1000000) return (count / 1000000).toFixed(1) + 'M';
    if (count >= 1000) return (count / 1000).toFixed(1) + 'K';
    return count.toString();
  }

  function toggleExpand() {
    expanded = !expanded;
  }
</script>

<div class="patterns-sidebar" class:collapsed={!expanded}>
  <div class="sidebar-header">
    <button class="expand-btn" on:click={toggleExpand} title={expanded ? 'Collapse' : 'Expand'}>
      <svg width="12" height="12" viewBox="0 0 12 12" class:rotated={!expanded}>
        <path fill="currentColor" d="M4 2l4 4-4 4V2z"/>
      </svg>
    </button>
    <h3>Patterns</h3>
    <button class="refresh-btn" on:click={fetchPatterns} disabled={$patternsLoading} title="Refresh patterns">
      <svg width="14" height="14" viewBox="0 0 14 14" class:spinning={$patternsLoading}>
        <path fill="currentColor" d="M7 1a6 6 0 0 0-6 6h2a4 4 0 0 1 4-4V1zm0 12a6 6 0 0 0 6-6h-2a4 4 0 0 1-4 4v2zM1 7a6 6 0 0 0 6 6v-2a4 4 0 0 1-4-4H1zm12 0a6 6 0 0 0-6-6v2a4 4 0 0 1 4 4h2z"/>
      </svg>
    </button>
  </div>

  {#if expanded}
    <div class="patterns-content">
      {#if $patternsError}
        <div class="error-state">
          <span>{$patternsError}</span>
        </div>
      {:else if $patternsLoading && $patterns.length === 0}
        <div class="loading-state">
          <span>Loading patterns...</span>
        </div>
      {:else if $patterns.length === 0}
        <div class="empty-state">
          <span>No patterns found</span>
        </div>
      {:else}
        <div class="patterns-list">
          {#each $patterns as pattern}
            <button
              class="pattern-item"
              class:selected={selectedPattern?.pattern_hash === pattern.pattern_hash}
              on:click={() => selectPattern(pattern)}
            >
              <div class="pattern-header">
                <span class="pattern-level" style="color: {getLevelColor(pattern.level)}">
                  {pattern.level}
                </span>
                <span class="pattern-service">{pattern.service}</span>
                <span class="pattern-count">{formatCount(pattern.count)}</span>
              </div>
              <div class="pattern-text">
                <!-- eslint-disable-next-line svelte/no-at-html-tags -->
                {@html highlightPattern(pattern.pattern)}
              </div>
            </button>
          {/each}
        </div>
      {/if}

      {#if selectedPattern && patternLogsLoading}
        <div class="pattern-detail">
          <div class="loading-state">Loading logs...</div>
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

  .expand-btn svg {
    transition: transform 0.2s;
  }

  .expand-btn svg.rotated {
    transform: rotate(180deg);
  }

  .refresh-btn svg.spinning {
    animation: spin 1s linear infinite;
  }

  @keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }

  .patterns-content {
    flex: 1;
    overflow-y: auto;
  }

  .loading-state,
  .empty-state,
  .error-state {
    padding: 20px;
    text-align: center;
    color: #8b949e;
    font-size: 13px;
  }

  .error-state {
    color: #f85149;
  }

  .patterns-list {
    display: flex;
    flex-direction: column;
  }

  .pattern-item {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 10px 12px;
    background: transparent;
    border: none;
    border-bottom: 1px solid #21262d;
    cursor: pointer;
    text-align: left;
    transition: background 0.1s;
    width: 100%;
  }

  .pattern-item:hover {
    background: #1c2128;
  }

  .pattern-item.selected {
    background: #388bfd15;
    border-left: 3px solid #58a6ff;
  }

  .pattern-header {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 11px;
  }

  .pattern-level {
    font-weight: 600;
    text-transform: uppercase;
  }

  .pattern-service {
    color: #58a6ff;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .pattern-count {
    color: #8b949e;
    background: #21262d;
    padding: 2px 6px;
    border-radius: 10px;
    font-weight: 500;
  }

  .pattern-text {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 11px;
    color: #c9d1d9;
    line-height: 1.4;
    overflow: hidden;
    text-overflow: ellipsis;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    word-break: break-all;
  }

  /* Placeholder highlighting */
  :global(.placeholder) {
    padding: 1px 4px;
    border-radius: 3px;
    font-weight: 600;
    font-size: 10px;
  }

  :global(.placeholder.uuid) {
    background: #a371f720;
    color: #a371f7;
  }

  :global(.placeholder.ip) {
    background: #3fb95020;
    color: #3fb950;
  }

  :global(.placeholder.num) {
    background: #58a6ff20;
    color: #58a6ff;
  }

  :global(.placeholder.datetime) {
    background: #d2992220;
    color: #d29922;
  }

  :global(.placeholder.hex) {
    background: #f8514920;
    color: #f85149;
  }

  .pattern-detail {
    padding: 12px;
    background: #0d1117;
    border-top: 1px solid #30363d;
  }
</style>
