<script>
  import { onMount } from 'svelte';
  import Button from './ui/Button.svelte';
  import LoadingSpinner from './ui/LoadingSpinner.svelte';
  import Icon from './ui/Icon.svelte';
  import EmptyState from './ui/EmptyState.svelte';
  import { play, xCircle, table, code, copy, search } from './ui/icons.js';
  import { error as toastError } from '../stores/toast.js';
  import { api } from '../utils/api.js';

  let query = '';
  let fromDate = '';
  let toDate = '';
  let limit = 100;
  let fields = '';
  let loading = false;
  let errorMessage = null;
  let results = null;
  let showJson = false;
  let queryTextarea;
  let executionTime = null;

  // Set default time range: last 24 hours
  onMount(() => {
    const now = new Date();
    const yesterday = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    toDate = formatDatetimeLocal(now);
    fromDate = formatDatetimeLocal(yesterday);
  });

  function formatDatetimeLocal(date) {
    const pad = (n) => String(n).padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  function handleKeydown(event) {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      executeQuery();
    }
  }

  async function executeQuery() {
    if (!query.trim()) {
      toastError('Query cannot be empty');
      return;
    }

    loading = true;
    errorMessage = null;
    results = null;
    executionTime = null;

    const startTime = performance.now();

    try {
      const body = {
        query: query.trim(),
        limit: Number(limit) || 100,
      };

      if (fromDate) {
        body.from = new Date(fromDate).toISOString();
      }
      if (toDate) {
        body.to = new Date(toDate).toISOString();
      }
      if (fields.trim()) {
        body.fields = fields.split(',').map(f => f.trim()).filter(Boolean);
      }

      const data = await api.post('/query', body);

      executionTime = ((performance.now() - startTime) / 1000).toFixed(2);
      results = data;
    } catch (err) {
      errorMessage = err.message;
      toastError(`Query failed: ${err.message}`);
    } finally {
      loading = false;
    }
  }

  function clearResults() {
    results = null;
    errorMessage = null;
    executionTime = null;
  }

  function copySQL() {
    if (results?.sql) {
      navigator.clipboard.writeText(results.sql);
    }
  }

  $: columns = results?.logs?.length > 0 ? Object.keys(results.logs[0]) : [];
  $: resultCount = results?.total ?? results?.logs?.length ?? 0;
</script>

<svelte:window on:keydown={handleKeydown} />

<div class="query-page">
  <!-- Header -->
  <header>
    <div class="header-left">
      <h1>Advanced Query</h1>
      <span class="header-hint">Write queries to search and analyze your logs</span>
    </div>
    <div class="header-right">
      {#if results}
        <button class="clear-btn" on:click={clearResults}>Clear Results</button>
      {/if}
    </div>
  </header>

  <!-- Query Editor Section -->
  <div class="editor-section">
    <div class="editor-header">
      <label for="query-editor" class="editor-label">Query</label>
      <span class="shortcut-hint">
        <kbd>{navigator.platform?.includes('Mac') ? 'Cmd' : 'Ctrl'}</kbd>
        <span>+</span>
        <kbd>Enter</kbd>
        <span>to execute</span>
      </span>
    </div>
    <textarea
      id="query-editor"
      bind:this={queryTextarea}
      bind:value={query}
      class="query-editor"
      placeholder='level:error AND message:"connection timeout"'
      rows="6"
      spellcheck="false"
    ></textarea>
  </div>

  <!-- Options Row -->
  <div class="options-row">
    <div class="option-group">
      <label for="from-date">From</label>
      <input
        id="from-date"
        type="datetime-local"
        bind:value={fromDate}
        class="option-input datetime-input"
      />
    </div>
    <div class="option-group">
      <label for="to-date">To</label>
      <input
        id="to-date"
        type="datetime-local"
        bind:value={toDate}
        class="option-input datetime-input"
      />
    </div>
    <div class="option-group">
      <label for="limit-input">Limit</label>
      <input
        id="limit-input"
        type="number"
        bind:value={limit}
        class="option-input limit-input"
        min="1"
        max="10000"
      />
    </div>
    <div class="option-group fields-group">
      <label for="fields-input">Fields</label>
      <input
        id="fields-input"
        type="text"
        bind:value={fields}
        class="option-input"
        placeholder="timestamp, level, message"
      />
    </div>
    <div class="option-group execute-group">
      <Button variant="primary" on:click={executeQuery} loading={loading}>
        <Icon icon={play} size={16} />
        Execute
      </Button>
    </div>
  </div>

  <!-- Loading State -->
  {#if loading}
    <div class="loading-container">
      <LoadingSpinner label="Executing query..." variant="primary" centered />
    </div>
  {/if}

  <!-- Error Display -->
  {#if errorMessage}
    <div class="error-banner">
      <Icon icon={xCircle} size={16} />
      <div class="error-content">
        <span class="error-title">Query Error</span>
        <span class="error-text">{errorMessage}</span>
      </div>
    </div>
  {/if}

  <!-- Results Section -->
  {#if results}
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
            on:click={() => showJson = false}
          >
            <Icon icon={table} size={14} />
            Table
          </button>
          <button
            class="toggle-btn"
            class:active={showJson}
            on:click={() => showJson = true}
          >
            <Icon icon={code} size={14} />
            JSON
          </button>
        </div>
      </div>

      <!-- SQL Debug Block -->
      {#if results.sql}
        <div class="sql-block">
          <div class="sql-header">
            <span class="sql-label">Generated SQL</span>
            <button class="copy-btn" on:click={copySQL} title="Copy SQL" aria-label="Copy generated SQL">
              <Icon icon={copy} size={14} />
            </button>
          </div>
          <pre class="sql-code">{results.sql}</pre>
        </div>
      {/if}

      <!-- Table View -->
      {#if !showJson}
        {#if results.logs && results.logs.length > 0}
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
                {#each results.logs as row, i}
                  <tr>
                    <td class="row-num">{i + 1}</td>
                    {#each columns as col}
                      <td>
                        <span class="cell-value" title={String(row[col] ?? '')}>
                          {row[col] ?? ''}
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
          <pre class="json-code">{JSON.stringify(results.logs, null, 2)}</pre>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .query-page {
    padding: 16px 20px;
    overflow-y: auto;
    height: calc(100vh - 60px);
  }

  /* Header */
  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
  }

  .header-left {
    display: flex;
    align-items: baseline;
    gap: 12px;
  }

  h1 {
    font-size: 1.25rem;
    font-weight: 600;
    color: #f0f6fc;
    margin: 0;
  }

  .header-hint {
    font-size: 0.8125rem;
    color: #8b949e;
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .clear-btn {
    padding: 4px 12px;
    background: transparent;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #8b949e;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .clear-btn:hover {
    background: #21262d;
    color: #c9d1d9;
    border-color: #8b949e;
  }

  /* Editor Section */
  .editor-section {
    margin-bottom: 12px;
  }

  .editor-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 6px;
  }

  .editor-label {
    font-size: 0.75rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .shortcut-hint {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 0.6875rem;
    color: #848d97;
  }

  kbd {
    display: inline-block;
    padding: 2px 6px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    font-family: var(--font-mono);
    font-size: 0.625rem;
    color: #8b949e;
    line-height: 1.4;
  }

  .query-editor {
    width: 100%;
    min-height: 120px;
    padding: 12px 14px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    color: #c9d1d9;
    font-family: var(--font-mono);
    font-size: 0.875rem;
    line-height: 1.6;
    resize: vertical;
    transition: border-color 0.15s;
    box-sizing: border-box;
  }

  .query-editor:focus {
    border-color: #58a6ff;
    box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.15);
  }

  .query-editor::placeholder {
    color: #484f58;
  }

  /* Options Row */
  .options-row {
    display: flex;
    align-items: flex-end;
    gap: 12px;
    margin-bottom: 16px;
    flex-wrap: wrap;
  }

  .option-group {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .option-group label {
    font-size: 0.6875rem;
    font-weight: 500;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .option-input {
    padding: 6px 10px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.8125rem;
    font-family: inherit;
    height: 34px;
    transition: border-color 0.15s;
    box-sizing: border-box;
  }

  .option-input:focus {
    border-color: #58a6ff;
    box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.15);
  }

  .datetime-input {
    width: 220px;
    color-scheme: dark;
  }

  .limit-input {
    width: 90px;
  }

  .fields-group {
    flex: 1;
    min-width: 180px;
  }

  .fields-group .option-input {
    width: 100%;
  }

  .execute-group {
    padding-bottom: 0;
  }

  /* Loading */
  .loading-container {
    padding: 32px 0;
  }

  /* Error Banner */
  .error-banner {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 12px 14px;
    background: rgba(248, 81, 73, 0.08);
    border: 1px solid rgba(248, 81, 73, 0.3);
    border-radius: 8px;
    margin-bottom: 16px;
  }

  /* :global — the icon is rendered by <Icon>, so it carries that component's
     scope class, not this one's. */
  .error-banner :global(svg) {
    color: #f85149;
    flex-shrink: 0;
    margin-top: 1px;
  }

  .error-content {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .error-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #f85149;
  }

  .error-text {
    font-size: 0.8125rem;
    color: #f0908a;
    word-break: break-word;
  }

  /* Results Section */
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

  /* SQL Block */
  .sql-block {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    margin-bottom: 12px;
    overflow: hidden;
  }

  .sql-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    border-bottom: 1px solid #21262d;
  }

  .sql-label {
    font-size: 0.6875rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .copy-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    background: transparent;
    border: none;
    border-radius: 4px;
    color: #848d97;
    cursor: pointer;
    transition: all 0.15s;
  }

  .copy-btn:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .sql-code {
    margin: 0;
    padding: 10px 14px;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    line-height: 1.5;
    color: #e6edf3;
    white-space: pre-wrap;
    word-break: break-all;
    overflow-x: auto;
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

  /* Responsive */
  @media (max-width: 900px) {
    .options-row {
      flex-direction: column;
      align-items: stretch;
    }

    .datetime-input {
      width: 100%;
    }

    .limit-input {
      width: 100%;
    }

    .header-left {
      flex-direction: column;
      gap: 2px;
    }

    .cell-value {
      max-width: 250px;
    }
  }
</style>
