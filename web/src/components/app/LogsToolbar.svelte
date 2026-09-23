<!--
  LogsToolbar
  The logs page's part of the app header: query bar, syntax-help button,
  cluster / time-range pickers, export menus and Refresh. Renders several
  root nodes on purpose — they are flex items of the header itself.
-->
<script>
  import SearchBar from '../SearchBar.svelte';
  import TimeRangePicker from '../TimeRangePicker.svelte';
  import ClusterSelector from '../ui/ClusterSelector.svelte';
  import Icon from '../ui/Icon.svelte';
  import HeaderMenu from './HeaderMenu.svelte';
  import { fileText, braces, save } from '../ui/icons.js';
  import { logs, loading, query, timeRange, customTimeRange, searchLogs } from '../../stores/logs.js';
  import { clusters } from '../../stores/cluster.js';
  import { success as toastSuccess } from '../../stores/toast.js';
  import { downloadBlob } from '../../utils/dom.js';
  import { downloadLogsCsv } from '../../utils/csv.js';

  /**
   * @type {{
   *   selectedLogs: Array<Record<string, any>>,
   *   exportStatus?: string,
   *   onsavesearch: () => void,
   *   onshowhelp: () => void,
   * }}
   */
  let { selectedLogs, exportStatus = $bindable(''), onsavesearch, onshowhelp } = $props();

  function handleTimeRangeChange({ range, from, to }) {
    $timeRange = range;
    if (range === 'custom' && from && to) {
      $customTimeRange = { from, to };
    } else {
      $customTimeRange = { from: null, to: null };
    }
    searchLogs();
  }

  // "Ask AI" → "Apply as search": the generated query becomes the search
  // query and runs, exactly as if it had been typed into the bar.
  // `query` (#98) is the search-bar syntax the server already validated with
  // the bar's own parser, so it wins over the raw SQL when present. It never
  // carries a time range, so the time picker is left alone.
  function applyAIQuery({ sql, query: searchQuery }) {
    const next = typeof searchQuery === 'string' && searchQuery.trim() ? searchQuery : sql;
    if (!next) return;
    $query = next;
    searchLogs();
  }

  function exportCSV(logsToExport) {
    if (!logsToExport || logsToExport.length === 0) return;

    if (logsToExport.length > 100) {
      exportStatus = 'preparing';
    }

    downloadLogsCsv(logsToExport, 'purl-logs');
    exportStatus = '';
    toastSuccess(`Exported ${logsToExport.length} logs as CSV`);
  }

  function exportJSON(logsToExport) {
    if (!logsToExport || logsToExport.length === 0) return;

    if (logsToExport.length > 100) {
      exportStatus = 'preparing';
    }

    const json = JSON.stringify(logsToExport, null, 2);
    downloadBlob(new Blob([json], { type: 'application/json' }), `purl-logs-${Date.now()}.json`);
    exportStatus = '';
    toastSuccess(`Exported ${logsToExport.length} logs as JSON`);
  }
</script>

{#snippet exportItems(rows, close, disabled)}
  <button onclick={() => { exportCSV(rows); close(); }} {disabled}>
    <Icon icon={fileText} size={14} strokeWidth={2.5} />
    Export CSV
  </button>
  <button onclick={() => { exportJSON(rows); close(); }} {disabled}>
    <Icon icon={braces} size={14} strokeWidth={2.5} />
    Export JSON
  </button>
{/snippet}

<SearchBar bind:value={$query} onsearch={searchLogs} onaiapply={applyAIQuery} />
<button
  class="search-help-btn"
  onclick={onshowhelp}
  title="Search syntax help"
  aria-label="Search syntax help"
>?</button>

<div class="header-actions">
  {#if $clusters.length > 0}
    <ClusterSelector onchange={() => searchLogs()} />
  {/if}
  <TimeRangePicker value={$timeRange} onchange={handleTimeRangeChange} />

  {#if selectedLogs.length > 0}
    <HeaderMenu selected>
      {#snippet label()}Export Selected ({selectedLogs.length}){/snippet}
      {#snippet children(close)}
        {@render exportItems(selectedLogs, close, false)}
      {/snippet}
    </HeaderMenu>
  {/if}

  <HeaderMenu>
    {#snippet label()}Actions{/snippet}
    {#snippet children(close)}
      <button onclick={() => { onsavesearch(); close(); }}>
        <Icon icon={save} size={14} strokeWidth={2.5} />
        Save Search
      </button>
      <div class="divider"></div>
      {@render exportItems($logs, close, $logs.length === 0)}
    {/snippet}
  </HeaderMenu>

  <button class="btn" onclick={() => searchLogs()} disabled={$loading}>
    {#if $loading}
      <span class="spinner"></span>
    {:else}
      Refresh
    {/if}
  </button>
</div>

<style>
  .header-actions {
    display: flex;
    gap: 8px;
    margin-left: auto;
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
    /* @keyframes spin lives in src/styles/animations.css (declared once). */
    animation: spin 0.8s linear infinite;
  }

  .search-help-btn {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    border: 1px solid #555;
    background: #2a2a3a;
    color: #888;
    font-size: 0.85rem;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .search-help-btn:hover {
    border-color: #7c3aed;
    color: #7c3aed;
  }

  @media (max-width: 768px) {
    .header-actions {
      gap: 4px;
    }
  }

  @media (max-width: 480px) {
    .btn {
      padding: 6px 10px;
      font-size: 12px;
    }
  }
</style>
