<script>
  import { createEventDispatcher } from 'svelte';
  import { aiLoading, aiError, aiQueryResult, aiQuerySQL, queryAI, aiSuggestions, fetchSuggestions, aiProvider } from '../../stores/ai.js';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';

  const dispatch = createEventDispatcher();

  let question = '';
  let showSuggestions = false;

  $: result = $aiQueryResult;
  $: sql = $aiQuerySQL;

  function handleKeydown(e) {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      submit();
    }
    if (e.key === 'Escape') {
      showSuggestions = false;
    }
  }

  async function submit() {
    if (!question.trim() || $aiLoading) return;
    showSuggestions = false;
    await queryAI(question.trim());
  }

  function applyQuery() {
    if (sql) {
      dispatch('apply', { sql, results: result?.results });
    }
  }

  function useSuggestion(s) {
    question = s;
    showSuggestions = false;
    submit();
  }

  function handleFocus() {
    if ($aiSuggestions.length === 0) fetchSuggestions();
    showSuggestions = true;
  }
</script>

<div class="ai-query-bar">
  <div class="ai-header">
    <span class="ai-badge">
      <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
        <path d="M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0ZM1.5 8a6.5 6.5 0 1 0 13 0 6.5 6.5 0 0 0-13 0Zm7-3.25v2.992l1.872 1.094a.75.75 0 0 1-.992 1.126l-2.25-1.314a.75.75 0 0 1-.378-.654V4.75a.75.75 0 0 1 1.5 0h-.252Z"/>
      </svg>
      Ask AI
    </span>
    <span class="provider-label">{$aiProvider}</span>
  </div>

  <div class="input-row">
    <!-- svelte-ignore a11y-no-static-element-interactions -->
    <div class="input-wrapper" on:focusin={handleFocus} on:focusout={() => setTimeout(() => { showSuggestions = false; }, 200)}>
      <textarea
        bind:value={question}
        on:keydown={handleKeydown}
        placeholder="Ask anything: Show me all errors from the last hour..."
        rows="2"
        disabled={$aiLoading}
        class="ai-input"
      ></textarea>

      {#if showSuggestions && $aiSuggestions.length > 0 && !question}
        <div class="suggestions-dropdown">
          {#each $aiSuggestions as s}
            <!-- svelte-ignore a11y-click-events-have-key-events -->
            <div class="suggestion-item" on:click={() => useSuggestion(s)}>
              <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
                <path d="M6 9.99l-2.72-2.72-1.06 1.06L6 12.11l8.78-8.78-1.06-1.06L6 9.99Z"/>
              </svg>
              {s}
            </div>
          {/each}
        </div>
      {/if}
    </div>

    <button
      class="send-btn"
      on:click={submit}
      disabled={$aiLoading || !question.trim()}
      title="Send (Ctrl+Enter)"
    >
      {#if $aiLoading}
        <LoadingSpinner size="sm" />
      {:else}
        <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
          <path d="M1.5 1.5l13 6.5-13 6.5V9l9.5-1.5L1.5 6V1.5Z"/>
        </svg>
      {/if}
    </button>
  </div>

  {#if $aiError}
    <div class="ai-error">
      <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
        <path d="M8 1a7 7 0 1 1 0 14A7 7 0 0 1 8 1Zm-.75 4.75v3.5h1.5v-3.5h-1.5Zm0 5v1.5h1.5v-1.5h-1.5Z"/>
      </svg>
      {$aiError}
    </div>
  {/if}

  {#if result && sql}
    <div class="ai-result">
      <div class="result-header">
        <span class="result-label">Generated SQL</span>
        <button class="apply-btn" on:click={applyQuery}>
          Apply as search
        </button>
      </div>
      <pre class="sql-block">{sql}</pre>

      {#if result.results && result.results.length > 0}
        <div class="result-count">{result.total} result{result.total !== 1 ? 's' : ''}</div>
        <div class="results-table-wrap">
          <table class="results-table">
            <thead>
              <tr>
                {#each Object.keys(result.results[0]) as col}
                  <th>{col}</th>
                {/each}
              </tr>
            </thead>
            <tbody>
              {#each result.results.slice(0, 20) as row}
                <tr>
                  {#each Object.values(row) as val}
                    <td>{val ?? ''}</td>
                  {/each}
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {:else if result.results}
        <div class="no-results">No results found.</div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .ai-query-bar {
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 8px;
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .ai-header {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .ai-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 12px;
    font-weight: 600;
    color: #58a6ff;
    background: rgba(88, 166, 255, 0.1);
    padding: 2px 8px;
    border-radius: 12px;
    border: 1px solid rgba(88, 166, 255, 0.3);
  }

  .provider-label {
    font-size: 11px;
    color: var(--text-secondary, #8b949e);
    text-transform: capitalize;
  }

  .input-row {
    display: flex;
    gap: 8px;
    align-items: flex-start;
  }

  .input-wrapper {
    flex: 1;
    position: relative;
  }

  .ai-input {
    width: 100%;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-primary, #c9d1d9);
    font-size: 13px;
    padding: 8px 10px;
    resize: none;
    font-family: inherit;
    box-sizing: border-box;
    transition: border-color 0.15s;
  }

  .ai-input:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .ai-input:disabled {
    opacity: 0.6;
  }

  .suggestions-dropdown {
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-top: none;
    border-radius: 0 0 6px 6px;
    z-index: 50;
    box-shadow: 0 4px 16px rgba(0,0,0,0.4);
  }

  .suggestion-item {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    font-size: 12px;
    color: var(--text-secondary, #8b949e);
    cursor: pointer;
    transition: background 0.1s;
  }

  .suggestion-item:hover {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .send-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    background: #238636;
    border: none;
    border-radius: 6px;
    color: #fff;
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.15s;
  }

  .send-btn:hover:not(:disabled) { background: #2ea043; }
  .send-btn:disabled { opacity: 0.4; cursor: not-allowed; }

  .ai-error {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: #f85149;
    background: rgba(248, 81, 73, 0.1);
    padding: 6px 10px;
    border-radius: 6px;
    border: 1px solid rgba(248, 81, 73, 0.3);
  }

  .ai-result {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .result-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .result-label {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .apply-btn {
    font-size: 12px;
    color: #58a6ff;
    background: rgba(88, 166, 255, 0.1);
    border: 1px solid rgba(88, 166, 255, 0.3);
    border-radius: 4px;
    padding: 3px 10px;
    cursor: pointer;
    transition: background 0.15s;
  }

  .apply-btn:hover { background: rgba(88, 166, 255, 0.2); }

  .sql-block {
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    padding: 8px 12px;
    font-size: 12px;
    font-family: 'Consolas', 'Monaco', monospace;
    color: #79c0ff;
    overflow-x: auto;
    white-space: pre-wrap;
    word-break: break-all;
    margin: 0;
  }

  .result-count {
    font-size: 12px;
    color: var(--text-secondary, #8b949e);
  }

  .results-table-wrap {
    overflow-x: auto;
    max-height: 300px;
    overflow-y: auto;
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
  }

  .results-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 12px;
  }

  .results-table th {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-secondary, #8b949e);
    padding: 6px 10px;
    text-align: left;
    font-weight: 600;
    white-space: nowrap;
    position: sticky;
    top: 0;
  }

  .results-table td {
    padding: 5px 10px;
    color: var(--text-primary, #c9d1d9);
    border-top: 1px solid var(--border-color, #30363d);
    max-width: 300px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .results-table tr:hover td { background: var(--bg-tertiary, #21262d); }

  .no-results {
    font-size: 12px;
    color: var(--text-secondary, #8b949e);
    text-align: center;
    padding: 12px;
  }
</style>
