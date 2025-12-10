<script>
  import { onMount } from 'svelte';
  import SearchBar from './components/SearchBar.svelte';
  import TimeRangePicker from './components/TimeRangePicker.svelte';
  import FieldsSidebar from './components/FieldsSidebar.svelte';
  import LogTable from './components/LogTable.svelte';
  import Histogram from './components/Histogram.svelte';
  import SavedSearches from './components/SavedSearches.svelte';
  import AlertsPanel from './components/AlertsPanel.svelte';
  import { logs, loading, query, timeRange, total, searchLogs, connectWebSocket } from './stores/logs.js';

  let ws;
  let liveMode = false;
  let savedSearchesRef;

  onMount(async () => {
    await searchLogs();
  });

  function toggleLiveMode() {
    liveMode = !liveMode;
    if (liveMode) {
      ws = connectWebSocket();
    } else if (ws) {
      ws.close();
      ws = null;
    }
  }

  function handleSearch() {
    searchLogs();
  }

  function handleTimeRangeChange(event) {
    $timeRange = event.detail;
    searchLogs();
  }

  function handleFieldFilter(event) {
    const { field, value } = event.detail;
    $query = `${field}:${value}`;
    searchLogs();
  }

  function handleApplySavedSearch(event) {
    const { query: q, timeRange: tr } = event.detail;
    $query = q;
    $timeRange = tr;
    searchLogs();
  }

  function saveCurrentSearch() {
    savedSearchesRef?.openSaveModal($query, $timeRange);
  }
</script>

<main>
  <header>
    <div class="logo">
      <svg width="32" height="32" viewBox="0 0 32 32">
        <circle cx="16" cy="16" r="14" fill="none" stroke="currentColor" stroke-width="2"/>
        <path d="M10 12 L22 12 M10 16 L22 16 M10 20 L18 20" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
      <span>Purl</span>
    </div>

    <SearchBar bind:value={$query} on:search={handleSearch} />

    <div class="header-actions">
      <TimeRangePicker value={$timeRange} on:change={handleTimeRangeChange} />

      <button class="btn" class:active={liveMode} on:click={toggleLiveMode} title={liveMode ? 'Stop live tail' : 'Start live tail'}>
        {#if liveMode}
          <span class="live-dot"></span> Live
        {:else}
          Live Tail
        {/if}
      </button>

      <button class="btn" on:click={saveCurrentSearch} title="Save current search">
        <svg width="14" height="14" viewBox="0 0 14 14">
          <path fill="currentColor" d="M11 1H3a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2ZM7 10a2 2 0 1 1 0-4 2 2 0 0 1 0 4Zm3-6H4V2h6v2Z"/>
        </svg>
      </button>

      <button class="btn" on:click={handleSearch} disabled={$loading}>
        {#if $loading}
          <span class="spinner"></span>
        {:else}
          Refresh
        {/if}
      </button>
    </div>
  </header>

  <div class="stats-bar">
    <span>{$total.toLocaleString()} logs</span>
    <span class="separator">|</span>
    <span>Time range: {$timeRange}</span>
    {#if $query}
      <span class="separator">|</span>
      <span>Query: <code>{$query}</code></span>
    {/if}
  </div>

  <div class="container">
    <aside class="sidebar">
      <FieldsSidebar on:filter={handleFieldFilter} />
      <SavedSearches bind:this={savedSearchesRef} on:apply={handleApplySavedSearch} />
      <AlertsPanel />
    </aside>

    <div class="main-content">
      <Histogram />
      <LogTable logs={$logs} />
    </div>
  </div>
</main>

<style>
  :global(*) {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }

  :global(body) {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
    background: #0d1117;
    color: #c9d1d9;
    line-height: 1.5;
  }

  main {
    min-height: 100vh;
    display: flex;
    flex-direction: column;
  }

  header {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 12px 20px;
    background: #161b22;
    border-bottom: 1px solid #30363d;
    position: sticky;
    top: 0;
    z-index: 100;
  }

  .logo {
    display: flex;
    align-items: center;
    gap: 8px;
    color: #58a6ff;
    font-weight: 600;
    font-size: 18px;
  }

  .header-actions {
    display: flex;
    gap: 8px;
    margin-left: auto;
  }

  .stats-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 20px;
    background: #0d1117;
    border-bottom: 1px solid #21262d;
    font-size: 12px;
    color: #8b949e;
  }

  .stats-bar .separator {
    color: #30363d;
  }

  .stats-bar code {
    background: #21262d;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #58a6ff;
  }

  .btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 14px;
    transition: all 0.2s;
  }

  .btn:hover {
    background: #30363d;
  }

  .btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .btn.active {
    background: #238636;
    border-color: #238636;
  }

  .live-dot {
    width: 8px;
    height: 8px;
    background: #3fb950;
    border-radius: 50%;
    animation: pulse 1.5s infinite;
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
  }

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .container {
    display: flex;
    flex: 1;
  }

  .sidebar {
    width: 280px;
    background: #161b22;
    border-right: 1px solid #30363d;
    padding: 16px;
    overflow-y: auto;
    max-height: calc(100vh - 100px);
  }

  .main-content {
    flex: 1;
    padding: 16px;
    overflow-x: auto;
  }
</style>
