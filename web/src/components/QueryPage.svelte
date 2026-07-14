<script>
  import { onMount } from 'svelte';
  import Button from './ui/Button.svelte';
  import LoadingSpinner from './ui/LoadingSpinner.svelte';
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
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <polygon points="5 3 19 12 5 21 5 3"></polygon>
        </svg>
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
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="12" cy="12" r="10"></circle>
        <line x1="15" y1="9" x2="9" y2="15"></line>
        <line x1="9" y1="9" x2="15" y2="15"></line>
      </svg>
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
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect>
              <line x1="3" y1="9" x2="21" y2="9"></line>
              <line x1="9" y1="21" x2="9" y2="9"></line>
            </svg>
            Table
          </button>
          <button
            class="toggle-btn"
            class:active={showJson}
            on:click={() => showJson = true}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="16 18 22 12 16 6"></polyline>
              <polyline points="8 6 2 12 8 18"></polyline>
            </svg>
            JSON
          </button>
        </div>
      </div>

      <!-- SQL Debug Block -->
      {#if results.sql}
        <div class="sql-block">
          <div class="sql-header">
            <span class="sql-label">Generated SQL</span>
            <button class="copy-btn" on:click={copySQL} title="Copy SQL">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                <path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"></path>
              </svg>
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
          <div class="empty-state">
            <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
              <circle cx="11" cy="11" r="8"></circle>
              <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
            </svg>
            <span>No results found</span>
          </div>
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
    color: #6e7681;
  }

  kbd {
    display: inline-block;
    padding: 2px 6px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
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
    font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
    font-size: 0.875rem;
    line-height: 1.6;
    resize: vertical;
    transition: border-color 0.15s;
    box-sizing: border-box;
  }

  .query-editor:focus {
    outline: none;
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
    outline: none;
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

  .error-banner svg {
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
    color: #6e7681;
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
    font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
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
    font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
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
    font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
    user-select: none;
  }

  .cell-value {
    display: inline-block;
    max-width: 500px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* Empty State */
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
    padding: 48px 0;
    color: #484f58;
    font-size: 0.875rem;
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
    font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
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
