<!--
  LogsView
  The logs page body: the stats strip, the left sidebar (fields, saved
  searches, alerts), histogram + log table, and the patterns column.
-->
<script>
  import { untrack } from 'svelte';
  import FieldsSidebar from '../FieldsSidebar.svelte';
  import SavedSearches from '../SavedSearches.svelte';
  import AlertsPanel from '../AlertsPanel.svelte';
  import PatternsSidebar from '../PatternsSidebar.svelte';
  import Histogram from '../Histogram.svelte';
  import LogTable from '../log/LogTable.svelte';
  import { logs, query, timeRange, customTimeRange, total, searchLogs } from '../../stores/logs.js';

  /**
   * @type {{
   *   isMobile: boolean,
   *   mobileMenuOpen?: boolean,
   *   selectedLogs?: Array<Record<string, any>>,
   *   savedSearches?: any,
   * }}
   */
  let {
    isMobile,
    mobileMenuOpen = $bindable(false),
    selectedLogs = $bindable([]),
    // The SavedSearches instance, handed up so the header's "Save Search"
    // can call its openSaveModal().
    savedSearches = $bindable(null),
  } = $props();

  function handleFieldFilter({ value }) {
    $query = value;
    searchLogs();
  }

  function handleApplySavedSearch({ query: q, timeRange: tr }) {
    $query = q;
    $timeRange = tr;
    searchLogs();
  }

  // A histogram click (one bucket) and a drag (a range) both narrow the
  // search to a custom window.
  function handleHistogramRange({ start, end }) {
    $timeRange = 'custom';
    $customTimeRange = { from: start, to: end };
    searchLogs();
  }

  // LogTable reports ids; resolve them to the full log objects for export.
  // Untracked: the table may call this from inside one of its own effects, and
  // reading `$logs` there would make that effect depend on the log list.
  function handleSelectionChange(detail) {
    untrack(() => {
      const ids = detail?.selected || [];
      if (ids.length === 0) {
        if (selectedLogs.length > 0) selectedLogs = [];
        return;
      }
      const idSet = new Set(ids);
      selectedLogs = $logs.filter(l => idSet.has(l.id));
    });
  }
</script>

<div class="stats-bar">
  <span>{$total.toLocaleString()} logs</span>
  <span class="separator">|</span>
  <span>Time range: {$timeRange}</span>
  {#if $query}
    <span class="separator">|</span>
    <span>Query: <code>{$query}</code></span>
  {/if}
  {#if selectedLogs.length > 0}
    <span class="separator">|</span>
    <span class="selection-info">{selectedLogs.length} selected</span>
  {/if}
</div>

<div class="container">
  {#if isMobile && mobileMenuOpen}
    <div class="sidebar-backdrop visible" onclick={() => mobileMenuOpen = false} onkeydown={() => mobileMenuOpen = false} role="button" tabindex="-1" aria-label="Close menu"></div>
  {/if}

  <aside class="sidebar" class:mobile-open={isMobile && mobileMenuOpen}>
    <FieldsSidebar onfilter={handleFieldFilter} />
    <SavedSearches bind:this={savedSearches} onapply={handleApplySavedSearch} />
    <AlertsPanel />
  </aside>

  <div class="main-content">
    <Histogram onfilter={handleHistogramRange} onzoom={handleHistogramRange} />
    <LogTable logs={$logs} onselectionchange={handleSelectionChange} />
  </div>

  <aside class="patterns-aside">
    <PatternsSidebar />
  </aside>
</div>

<style>
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
    font-family: var(--font-mono);
    color: #58a6ff;
  }

  .selection-info {
    color: #58a6ff;
    font-weight: 500;
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

  .sidebar-backdrop {
    display: none;
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    z-index: 99;
  }

  .sidebar-backdrop.visible {
    display: block;
  }

  @media (max-width: 768px) {
    .sidebar {
      position: fixed;
      left: -280px;
      top: 0;
      height: 100vh;
      z-index: 100;
      transition: left 0.3s ease;
      background: #161b22;
    }

    .sidebar.mobile-open {
      left: 0;
    }

    .main-content {
      margin-left: 0 !important;
    }

    .patterns-aside {
      display: none;
    }
  }

  @media (max-width: 480px) {
    .stats-bar {
      flex-wrap: wrap;
      gap: 4px;
      padding: 6px 12px;
    }
  }
</style>
