<script>
  import { onMount } from 'svelte';
  import SearchBar from './components/SearchBar.svelte';
  import TimeRangePicker from './components/TimeRangePicker.svelte';
  import FieldsSidebar from './components/FieldsSidebar.svelte';
  import LogTable from './components/LogTable.svelte';
  import Histogram from './components/Histogram.svelte';
  import SavedSearches from './components/SavedSearches.svelte';
  import AlertsPanel from './components/AlertsPanel.svelte';
  import PatternsSidebar from './components/PatternsSidebar.svelte';
  import AnalyticsPage from './components/AnalyticsPage.svelte';
  import SettingsPage from './components/SettingsPage.svelte';
  import {
    logs,
    loading,
    error,
    query,
    timeRange,
    customTimeRange,
    total,
    searchLogs,
  } from './stores/logs.js';

  let savedSearchesRef;
  let currentPage = 'logs'; // 'logs' | 'analytics' | 'settings'

  // Dismiss error
  function dismissError() {
    error.set(null);
  }

  onMount(async () => {
    // Check URL hash for navigation
    handleHashChange();
    window.addEventListener('hashchange', handleHashChange);

    if (currentPage === 'logs') {
      await searchLogs();
    }

    return () => window.removeEventListener('hashchange', handleHashChange);
  });

  function handleHashChange() {
    const hash = window.location.hash.slice(1) || 'logs';
    if (['logs', 'analytics', 'settings'].includes(hash)) {
      currentPage = hash;
    }
  }

  function navigate(page) {
    currentPage = page;
    window.location.hash = page;
  }

  function handleSearch() {
    searchLogs();
  }

  function handleTimeRangeChange(event) {
    const { range, from, to } = event.detail;
    $timeRange = range;
    if (range === 'custom' && from && to) {
      $customTimeRange = { from, to };
    } else {
      $customTimeRange = { from: null, to: null };
    }
    searchLogs();
  }

  function handleFieldFilter(event) {
    const { value } = event.detail;
    $query = value;
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

  function exportCSV() {
    if ($logs.length === 0) return;

    const headers = ['timestamp', 'level', 'service', 'host', 'message'];
    const csvRows = [headers.join(',')];

    for (const log of $logs) {
      const row = headers.map((h) => {
        const val = log[h] || '';
        const escaped = String(val).replace(/"/g, '""');
        return /[,\n"]/.test(escaped) ? `"${escaped}"` : escaped;
      });
      csvRows.push(row.join(','));
    }

    const blob = new Blob([csvRows.join('\n')], {
      type: 'text/csv;charset=utf-8;',
    });
    downloadBlob(blob, `purl-logs-${Date.now()}.csv`);
  }

  function exportJSON() {
    if ($logs.length === 0) return;

    const data = $logs.map((log) => ({
      timestamp: log.timestamp,
      level: log.level,
      service: log.service,
      host: log.host,
      message: log.message,
      meta: log.meta || {},
    }));

    const blob = new Blob([JSON.stringify(data, null, 2)], {
      type: 'application/json',
    });
    downloadBlob(blob, `purl-logs-${Date.now()}.json`);
  }

  function downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }
</script>

<main>
  <header>
    <button class="logo" on:click={() => navigate('logs')}>
      <svg width="32" height="32" viewBox="0 0 32 32">
        <circle
          cx="16"
          cy="16"
          r="14"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        />
        <path
          d="M10 12 L22 12 M10 16 L22 16 M10 20 L18 20"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
        />
      </svg>
      <span>Purl</span>
    </button>

    <nav class="nav-tabs">
      <button
        class:active={currentPage === 'logs'}
        on:click={() => navigate('logs')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z" />
          <path d="M14 2v6h6M16 13H8M16 17H8M10 9H8" />
        </svg>
        Logs
      </button>
      <button
        class:active={currentPage === 'analytics'}
        on:click={() => navigate('analytics')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <path d="M3 3v18h18" />
          <path d="M18 9l-5-6-4 8-3-2" />
        </svg>
        Analytics
      </button>
      <button
        class:active={currentPage === 'settings'}
        on:click={() => navigate('settings')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <circle cx="12" cy="12" r="3" />
          <path
            d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-2 2 2 2 0 01-2-2v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83 0 2 2 0 010-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 01-2-2 2 2 0 012-2h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 010-2.83 2 2 0 012.83 0l.06.06a1.65 1.65 0 001.82.33H9a1.65 1.65 0 001-1.51V3a2 2 0 012-2 2 2 0 012 2v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 0 2 2 0 010 2.83l-.06.06a1.65 1.65 0 00-.33 1.82V9a1.65 1.65 0 001.51 1H21a2 2 0 012 2 2 2 0 01-2 2h-.09a1.65 1.65 0 00-1.51 1z"
          />
        </svg>
        Settings
      </button>
    </nav>

    {#if currentPage === 'logs'}
      <SearchBar bind:value={$query} on:search={handleSearch} />

      <div class="header-actions">
        <TimeRangePicker value={$timeRange} on:change={handleTimeRangeChange} />

        <div class="actions-dropdown">
          <button class="btn dropdown-trigger">
            Actions
            <svg
              width="12"
              height="12"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"><path d="M6 9l6 6 6-6" /></svg
            >
          </button>

          <div class="dropdown-menu">
            <button on:click={saveCurrentSearch}>
              <svg width="14" height="14" viewBox="0 0 14 14"
                ><path
                  fill="currentColor"
                  d="M11 1H3a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2ZM7 10a2 2 0 1 1 0-4 2 2 0 0 1 0 4Zm3-6H4V2h6v2Z"
                /></svg
              >
              Save Search
            </button>
            <div class="divider"></div>
            <button on:click={exportCSV} disabled={$logs.length === 0}>
              <svg width="14" height="14" viewBox="0 0 14 14"
                ><path
                  fill="currentColor"
                  d="M2 1h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1Zm1 3h6v1H3V4Zm0 2h6v1H3V6Zm0 2h4v1H3V8Z"
                /></svg
              >
              Export CSV
            </button>
            <button on:click={exportJSON} disabled={$logs.length === 0}>
              <svg width="14" height="14" viewBox="0 0 14 14"
                ><path
                  fill="currentColor"
                  d="M3 2a1 1 0 0 0-1 1v2a1 1 0 0 1-1 1 1 1 0 0 1 1 1v2a1 1 0 0 0 1 1M9 2a1 1 0 0 1 1 1v2a1 1 0 0 0 1 1 1 1 0 0 0-1 1v2a1 1 0 0 1-1 1"
                /></svg
              >
              Export JSON
            </button>
          </div>
        </div>

        <button class="btn" on:click={handleSearch} disabled={$loading}>
          {#if $loading}
            <span class="spinner"></span>
          {:else}
            Refresh
          {/if}
        </button>
      </div>
    {/if}
  </header>

  {#if $error}
    <div class="error-banner" role="alert">
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
        <path
          fill="currentColor"
          d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-2.75a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0V6a.75.75 0 0 1 .75-.75Zm0 7a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
        />
      </svg>
      <span>{$error}</span>
      <button
        class="dismiss-btn"
        on:click={dismissError}
        aria-label="Dismiss error"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
          <path
            fill="currentColor"
            d="M7 5.586 3.707 2.293a1 1 0 0 0-1.414 1.414L5.586 7 2.293 10.293a1 1 0 1 0 1.414 1.414L7 8.414l3.293 3.293a1 1 0 0 0 1.414-1.414L8.414 7l3.293-3.293a1 1 0 0 0-1.414-1.414L7 5.586Z"
          />
        </svg>
      </button>
    </div>
  {/if}

  {#if currentPage === 'logs'}
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
        <SavedSearches
          bind:this={savedSearchesRef}
          on:apply={handleApplySavedSearch}
        />
        <AlertsPanel />
      </aside>

      <div class="main-content">
        <Histogram />
        <LogTable logs={$logs} />
      </div>

      <aside class="patterns-aside">
        <PatternsSidebar />
      </aside>
    </div>
  {:else if currentPage === 'analytics'}
    <AnalyticsPage />
  {:else if currentPage === 'settings'}
    <SettingsPage />
  {/if}
</main>

<style>
  :global(*) {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }

  :global(body) {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen,
      Ubuntu, sans-serif;
    background: #0d1117;
    color: #c9d1d9;
    line-height: 1.5;
    overflow: hidden;
  }

  main {
    height: 100vh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
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
    background: none;
    border: none;
    cursor: pointer;
    padding: 0;
  }

  .logo:hover {
    color: #79c0ff;
  }

  .nav-tabs {
    display: flex;
    gap: 4px;
    background: #0d1117;
    padding: 4px;
    border-radius: 8px;
  }

  .nav-tabs button {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 14px;
    background: transparent;
    border: none;
    border-radius: 6px;
    color: #8b949e;
    font-size: 13px;
    cursor: pointer;
    transition: all 0.2s;
  }

  .nav-tabs button:hover {
    color: #c9d1d9;
    background: #21262d;
  }

  .nav-tabs button.active {
    color: #f0f6fc;
    background: #21262d;
  }

  .nav-tabs button svg {
    opacity: 0.7;
  }

  .nav-tabs button.active svg {
    opacity: 1;
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
    font-family: "SFMono-Regular", Consolas, monospace;
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

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .container {
    display: flex;
    flex: 1;
    overflow: hidden;
    max-height: calc(100vh - 100px);
  }

  .sidebar {
    width: 280px;
    background: #161b22;
    border-right: 1px solid #30363d;
    padding: 16px;
    overflow-y: auto;
    flex-shrink: 0;
  }

  .main-content {
    flex: 1;
    padding: 16px;
    overflow: auto;
  }

  .patterns-aside {
    padding: 16px;
    padding-left: 0;
    flex-shrink: 0;
  }

  .actions-dropdown {
    position: relative;
  }

  .actions-dropdown:hover .dropdown-menu,
  .actions-dropdown:focus-within .dropdown-menu {
    display: block;
  }

  .dropdown-trigger {
    padding-right: 12px;
  }

  .dropdown-trigger svg {
    opacity: 0.6;
    margin-left: 2px;
  }

  .dropdown-menu {
    display: none;
    position: absolute;
    top: 100%;
    right: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 200;
    min-width: 160px;
    overflow: hidden;
    padding: 4px 0;
  }

  .dropdown-menu button {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px 14px;
    background: none;
    border: none;
    color: #c9d1d9;
    font-size: 13px;
    cursor: pointer;
    text-align: left;
    transition: background 0.15s;
  }

  .dropdown-menu button:hover {
    background: #21262d;
  }

  .dropdown-menu button:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .dropdown-menu button svg {
    color: #8b949e;
  }

  .divider {
    height: 1px;
    background: #30363d;
    margin: 4px 0;
  }

  /* Error banner */
  .error-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 16px;
    background: rgba(248, 81, 73, 0.1);
    border-bottom: 1px solid #f85149;
    color: #f85149;
    font-size: 13px;
  }

  .error-banner svg {
    flex-shrink: 0;
  }

  .error-banner span {
    flex: 1;
  }

  .dismiss-btn {
    padding: 4px;
    background: none;
    border: none;
    color: #f85149;
    cursor: pointer;
    border-radius: 4px;
    opacity: 0.7;
    transition: opacity 0.15s;
  }

  .dismiss-btn:hover {
    opacity: 1;
    background: rgba(248, 81, 73, 0.2);
  }
</style>
