<!--
  QueryResults
  One executed query's result set: count + timing, the Table/JSON toggle, the
  generated SQL (with a copy button) and the rows themselves. QueryPage owns
  the result and the view mode, so the chosen view survives the next run.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import EmptyState from '../ui/EmptyState.svelte';
  import { table, code, search } from '../ui/icons.js';

  let {
    /** POST /api/query response: { hits, total } (Controller/Logs.pm::query) */
    results,
    /** Field names the query asked for; empty = every field of the first row */
    fields = [],
    /** Seconds the request took, as a fixed-point string, or null */
    executionTime = null,
    /** Show the raw JSON instead of the table */
    showJson = false,
    /** (showJson: boolean) => void */
    onviewchange,
  } = $props();

  const rows = $derived(results?.hits ?? []);
  // The API returns whole rows; the Fields option narrows the columns shown.
  const columns = $derived(
    fields.length > 0 ? fields : rows.length > 0 ? Object.keys(rows[0]) : [],
  );
  const resultCount = $derived(results?.total ?? rows.length);

  /** A cell's text: objects (e.g. `meta`) as JSON, not "[object Object]". */
  function cellText(value) {
    if (value == null) return '';
    return typeof value === 'object' ? JSON.stringify(value) : String(value);
  }
</script>

<div class="results-section">
  <!-- Results Header -->
  <div class="results-header">
    <div class="results-meta">
      <span class="results-count">
        {resultCount.toLocaleString()} {resultCount === 1 ? 'result' : 'results'}
      </span>
      {#if executionTime}
        <span class="execution-time">{executionTime}s</span>
      {/if}
    </div>
    <div class="results-actions">
      <button
        class="toggle-btn"
        class:active={!showJson}
        onclick={() => onviewchange(false)}
      >
        <Icon icon={table} size={14} />
        Table
      </button>
      <button
        class="toggle-btn"
        class:active={showJson}
        onclick={() => onviewchange(true)}
      >
        <Icon icon={code} size={14} />
        JSON
      </button>
    </div>
  </div>

  <!-- Table View -->
  {#if !showJson}
    {#if rows.length > 0}
      <div class="table-wrapper">
        <table class="results-table">
          <thead>
            <tr>
              <th class="row-num">#</th>
              {#each columns as col}
                <th>{col}</th>
              {/each}
            </tr>
          </thead>
          <tbody>
            {#each rows as row, i}
              <tr>
                <td class="row-num">{i + 1}</td>
                {#each columns as col}
                  <td>
                    <span class="cell-value" title={cellText(row[col])}>
                      {cellText(row[col])}
                    </span>
                  </td>
                {/each}
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else}
      <EmptyState icon={search} title="No results found" />
    {/if}
  {:else}
    <!-- JSON View -->
    <div class="json-wrapper">
      <pre class="json-code">{JSON.stringify(rows, null, 2)}</pre>
    </div>
  {/if}
</div>

<style>
  .results-section {
    margin-top: 4px;
  }

  .results-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }

  .results-meta {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .results-count {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #c9d1d9;
  }

  .execution-time {
    font-size: 0.75rem;
    color: #8b949e;
    padding: 2px 8px;
    background: #21262d;
    border-radius: 10px;
  }

  .results-actions {
    display: flex;
    gap: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    padding: 2px;
  }

  .toggle-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 4px 10px;
    background: transparent;
    border: none;
    border-radius: 4px;
    color: #8b949e;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .toggle-btn:hover {
    color: #c9d1d9;
  }

  .toggle-btn.active {
    background: #21262d;
    color: #f0f6fc;
  }

  /* Results Table */
  .table-wrapper {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: auto;
    max-height: calc(100vh - 420px);
  }

  .results-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.8125rem;
  }

  .results-table thead {
    position: sticky;
    top: 0;
    z-index: 1;
  }

  .results-table th {
    padding: 8px 12px;
    background: #21262d;
    border-bottom: 1px solid #30363d;
    color: #8b949e;
    font-weight: 600;
    font-size: 0.6875rem;
    text-transform: uppercase;
    letter-spacing: 0.3px;
    text-align: left;
    white-space: nowrap;
  }

  .results-table td {
    padding: 6px 12px;
    border-bottom: 1px solid #21262d;
    color: #c9d1d9;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    vertical-align: top;
  }

  .results-table tbody tr:hover {
    background: rgba(88, 166, 255, 0.04);
  }

  .results-table tbody tr:last-child td {
    border-bottom: none;
  }

  .row-num {
    color: #484f58;
    font-size: 0.6875rem;
    text-align: right;
    width: 40px;
    min-width: 40px;
    font-family: var(--font-mono);
    user-select: none;
  }

  .cell-value {
    display: inline-block;
    max-width: 500px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* JSON View */
  .json-wrapper {
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: auto;
    max-height: calc(100vh - 420px);
  }

  .json-code {
    margin: 0;
    padding: 14px 16px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    line-height: 1.6;
    color: #c9d1d9;
    white-space: pre;
  }

  @media (max-width: 900px) {
    .cell-value {
      max-width: 250px;
    }
  }
</style>
