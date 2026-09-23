<script>
  import { onMount } from 'svelte';
  import LoadingSpinner from './ui/LoadingSpinner.svelte';
  import Icon from './ui/Icon.svelte';
  import QueryOptions from './query/QueryOptions.svelte';
  import QueryResults from './query/QueryResults.svelte';
  import { xCircle } from './ui/icons.js';
  import { error as toastError } from '../stores/toast.js';
  import { api } from '../utils/api.js';

  let query = $state('');
  let fromDate = $state('');
  let toDate = $state('');
  let limit = $state(100);
  let fields = $state('');
  let loading = $state(false);
  let errorMessage = $state(null);
  // Raw: a result set is replaced wholesale, never mutated, and can be large.
  let results = $state.raw(null);
  let showJson = $state(false);
  let executionTime = $state(null);

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
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="query-page">
  <!-- Header -->
  <header>
    <div class="header-left">
      <h1>Advanced Query</h1>
      <span class="header-hint">Write queries to search and analyze your logs</span>
    </div>
    <div class="header-right">
      {#if results}
        <button class="clear-btn" onclick={clearResults}>Clear Results</button>
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
      bind:value={query}
      class="query-editor"
      placeholder='level:error AND message:"connection timeout"'
      rows="6"
      spellcheck="false"
    ></textarea>
  </div>

  <!-- Options Row -->
  <QueryOptions
    bind:fromDate
    bind:toDate
    bind:limit
    bind:fields
    {loading}
    onexecute={executeQuery}
  />

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
    <QueryResults
      {results}
      {executionTime}
      {showJson}
      onviewchange={(value) => showJson = value}
    />
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

  /* Responsive */
  @media (max-width: 900px) {
    .header-left {
      flex-direction: column;
      gap: 2px;
    }
  }
</style>
