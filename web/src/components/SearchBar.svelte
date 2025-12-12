<script>
  import { createEventDispatcher, onMount, onDestroy } from 'svelte';
  import { levelStats, serviceStats, hostStats, connectWebSocket, isLive } from '../stores/logs.js';

  export let value = '';

  const dispatch = createEventDispatcher();

  // Autocomplete state
  let showSuggestions = false;
  let suggestions = [];
  let selectedIndex = -1;
  let inputEl;

  // Search history
  let searchHistory = [];
  let showHistory = false;
  const MAX_HISTORY = 10;
  
  // Live mode
  let ws = null;

  // KQL operators and fields
  const OPERATORS = ['AND', 'OR', 'NOT'];
  const FIELDS = ['level', 'service', 'host', 'message', 'timestamp'];

  onMount(() => {
    const saved = localStorage.getItem('purl_search_history');
    if (saved) {
      searchHistory = JSON.parse(saved);
    }
  });

  onDestroy(() => {
    if (ws) {
      ws.close();
      isLive.set(false);
    }
  });

  function toggleLive() {
    if ($isLive) {
      if (ws) ws.close();
      ws = null;
      isLive.set(false);
    } else {
      ws = connectWebSocket();
      isLive.set(true);
      
      // Clear current search when going live
      if (value) {
        value = '';
        dispatch('search'); 
      }
    }
  }

  function saveToHistory(query) {
    if (!query.trim()) return;
    searchHistory = [query, ...searchHistory.filter(h => h !== query)].slice(0, MAX_HISTORY);
    localStorage.setItem('purl_search_history', JSON.stringify(searchHistory));
  }

  function handleKeydown(event) {
    // Disable live mode on search
    if (event.key === 'Enter' && $isLive) {
      toggleLive();
    }
    
    if (showSuggestions && suggestions.length > 0) {
      if (event.key === 'ArrowDown') {
        event.preventDefault();
        selectedIndex = Math.min(selectedIndex + 1, suggestions.length - 1);
      } else if (event.key === 'ArrowUp') {
        event.preventDefault();
        selectedIndex = Math.max(selectedIndex - 1, -1);
      } else if (event.key === 'Enter' && selectedIndex >= 0) {
        event.preventDefault();
        applySuggestion(suggestions[selectedIndex]);
        return;
      } else if (event.key === 'Escape') {
        showSuggestions = false;
        showHistory = false;
        return;
      }
    }

    if (event.key === 'Enter') {
      showSuggestions = false;
      showHistory = false;
      saveToHistory(value);
      dispatch('search');
    }
  }

  function handleInput() {
    selectedIndex = -1;
    updateSuggestions();
  }

  function handleFocus() {
    if (!value && searchHistory.length > 0) {
      showHistory = true;
    } else {
      updateSuggestions();
    }
  }

  function handleBlur() {
    setTimeout(() => {
      showSuggestions = false;
      showHistory = false;
    }, 200);
  }

  function updateSuggestions() {
    showHistory = false;
    const cursorPos = inputEl?.selectionStart || value.length;
    const textBeforeCursor = value.substring(0, cursorPos);

    // Get the current token being typed
    const tokens = textBeforeCursor.split(/\s+/);
    const currentToken = tokens[tokens.length - 1] || '';

    if (!currentToken) {
      showSuggestions = false;
      return;
    }

    suggestions = [];

    // Check if typing field:value
    if (currentToken.includes(':')) {
      const [field, partial] = currentToken.split(':');
      const fieldLower = field.toLowerCase();

      // Get values for this field
      let values = [];
      if (fieldLower === 'level') {
        values = $levelStats.map(s => s.value);
      } else if (fieldLower === 'service') {
        values = $serviceStats.map(s => s.value);
      } else if (fieldLower === 'host') {
        values = $hostStats.map(s => s.value);
      }

      // Filter by partial match
      const partialLower = (partial || '').toLowerCase();
      suggestions = values
        .filter(v => v.toLowerCase().includes(partialLower))
        .slice(0, 8)
        .map(v => ({
          type: 'value',
          text: `${field}:${v}`,
          display: v,
          field: field
        }));
    } else {
      // Suggest fields or operators
      const tokenLower = currentToken.toLowerCase();

      // Field suggestions
      const fieldSuggestions = FIELDS
        .filter(f => f.toLowerCase().startsWith(tokenLower))
        .map(f => ({
          type: 'field',
          text: `${f}:`,
          display: f,
          hint: 'field'
        }));

      // Operator suggestions (only after space)
      const opSuggestions = tokens.length > 1 ? OPERATORS
        .filter(op => op.toLowerCase().startsWith(tokenLower))
        .map(op => ({
          type: 'operator',
          text: op,
          display: op,
          hint: 'operator'
        })) : [];

      suggestions = [...fieldSuggestions, ...opSuggestions].slice(0, 8);
    }

    showSuggestions = suggestions.length > 0;
  }

  function applySuggestion(suggestion) {
    const cursorPos = inputEl?.selectionStart || value.length;
    const textBeforeCursor = value.substring(0, cursorPos);
    const textAfterCursor = value.substring(cursorPos);

    // Find the start of current token
    const lastSpace = textBeforeCursor.lastIndexOf(' ');
    const beforeToken = textBeforeCursor.substring(0, lastSpace + 1);

    value = beforeToken + suggestion.text + (suggestion.type === 'field' ? '' : ' ') + textAfterCursor.trimStart();
    showSuggestions = false;
    selectedIndex = -1;

    // Focus back to input
    setTimeout(() => inputEl?.focus(), 0);
  }

  function applyHistory(query) {
    value = query;
    showHistory = false;
    dispatch('search');
  }

  function clearHistory() {
    searchHistory = [];
    localStorage.removeItem('purl_search_history');
    showHistory = false;
  }

  function handleClear() {
    value = '';
    dispatch('search');
  }
</script>

<div class="search-bar" role="search">
  <button class="live-btn" class:active={$isLive} on:click={toggleLive} title="Toggle Live Mode">
    <span class="live-indicator"></span>
    Live
  </button>

  <div class="search-con">
    <svg class="search-icon" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
      <path fill="currentColor" d="M11.5 7a4.5 4.5 0 1 1-9 0 4.5 4.5 0 0 1 9 0Zm-.82 4.74a6 6 0 1 1 1.06-1.06l3.04 3.04a.75.75 0 1 1-1.06 1.06l-3.04-3.04Z"/>
    </svg>

  <input
    bind:this={inputEl}
    type="text"
    bind:value
    on:keydown={handleKeydown}
    on:input={handleInput}
    on:focus={handleFocus}
    on:blur={handleBlur}
    placeholder="Search logs... level:ERROR AND service:api*"
    autocomplete="off"
    aria-label="Search logs"
    aria-autocomplete="list"
    aria-controls={showSuggestions ? 'search-suggestions' : undefined}
  />

  {#if value}
    <button class="clear-btn" on:click={handleClear} title="Clear search" aria-label="Clear search">
      <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
        <path fill="currentColor" d="M7 5.586 3.707 2.293a1 1 0 0 0-1.414 1.414L5.586 7 2.293 10.293a1 1 0 1 0 1.414 1.414L7 8.414l3.293 3.293a1 1 0 0 0 1.414-1.414L8.414 7l3.293-3.293a1 1 0 0 0-1.414-1.414L7 5.586Z"/>
      </svg>
    </button>
  {/if}

  <!-- Autocomplete dropdown -->
  {#if showSuggestions && suggestions.length > 0}
    <div class="suggestions" id="search-suggestions" role="listbox" aria-label="Search suggestions">
      {#each suggestions as suggestion, i}
        <button
          class="suggestion-item"
          class:selected={i === selectedIndex}
          on:mousedown|preventDefault={() => applySuggestion(suggestion)}
          role="option"
          aria-selected={i === selectedIndex}
        >
          <span class="suggestion-icon">
            {#if suggestion.type === 'field'}
              <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M2 3h8v1H2V3zm0 2.5h8v1H2v-1zm0 2.5h5v1H2V8z"/></svg>
            {:else if suggestion.type === 'operator'}
              <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M6 1v10M1 6h10" stroke="currentColor" stroke-width="1.5"/></svg>
            {:else}
              <svg width="12" height="12" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4" fill="currentColor"/></svg>
            {/if}
          </span>
          <span class="suggestion-text">{suggestion.display}</span>
          {#if suggestion.hint}
            <span class="suggestion-hint">{suggestion.hint}</span>
          {/if}
          {#if suggestion.field}
            <span class="suggestion-field">{suggestion.field}</span>
          {/if}
        </button>
      {/each}
    </div>
  {/if}

  {#if showHistory && searchHistory.length > 0}
    <div class="suggestions history">
      <div class="history-header">
        <span>Recent searches</span>
        <button class="history-clear" on:mousedown|preventDefault={clearHistory}>Clear</button>
      </div>
      {#each searchHistory as query}
        <button
          class="suggestion-item"
          on:mousedown|preventDefault={() => applyHistory(query)}
        >
          <span class="suggestion-icon">
            <svg width="12" height="12" viewBox="0 0 12 12"><path fill="currentColor" d="M6 1a5 5 0 1 0 5 5 5 5 0 0 0-5-5zm0 9a4 4 0 1 1 4-4 4 4 0 0 1-4 4zm.5-4V3.5a.5.5 0 0 0-1 0v3a.5.5 0 0 0 .15.35l2 2a.5.5 0 0 0 .7-.7L6.5 6z"/></svg>
          </span>
          <span class="suggestion-text history-query">{query}</span>
        </button>
      {/each}
    </div>
  {/if}
  </div>
</div>

<style>
  .search-bar {
    flex: 1;
    max-width: 600px;
    position: relative;
    display: flex;
    align-items: center;
  }

  .search-con {
    flex: 1;
    position: relative;
    display: flex;
    align-items: center;
  }
  
  .live-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0 12px;
    height: 38px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #8b949e;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    margin-right: 12px;
    transition: all 0.15s;
  }

  .live-btn:hover {
    border-color: #8b949e;
    color: #c9d1d9;
  }

  .live-btn.active {
    background: #3fb95020;
    border-color: #3fb950;
    color: #3fb950;
  }

  .live-indicator {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #8b949e;
  }

  .live-btn.active .live-indicator {
    background: #3fb950;
    box-shadow: 0 0 6px #3fb95060;
  }

  .search-icon {
    position: absolute;
    left: 12px;
    color: #8b949e;
    pointer-events: none;
    z-index: 1;
  }

  input {
    width: 100%;
    padding: 10px 36px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 14px;
    font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
  }

  input:focus {
    outline: none;
    border-color: #58a6ff;
    box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.15);
  }

  input::placeholder {
    color: #6e7681;
  }

  .clear-btn {
    position: absolute;
    right: 8px;
    padding: 4px;
    background: none;
    border: none;
    color: #8b949e;
    cursor: pointer;
    border-radius: 4px;
    z-index: 1;
  }

  .clear-btn:hover {
    color: #c9d1d9;
    background: #30363d;
  }

  .suggestions {
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 100;
    overflow: hidden;
  }

  .history-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    border-bottom: 1px solid #30363d;
    font-size: 11px;
    color: #8b949e;
    text-transform: uppercase;
  }

  .history-clear {
    background: none;
    border: none;
    color: #58a6ff;
    cursor: pointer;
    font-size: 11px;
    text-transform: uppercase;
  }

  .history-clear:hover {
    text-decoration: underline;
  }

  .suggestion-item {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px 12px;
    background: none;
    border: none;
    color: #c9d1d9;
    text-align: left;
    cursor: pointer;
    font-size: 13px;
  }

  .suggestion-item:hover,
  .suggestion-item.selected {
    background: #21262d;
  }

  .suggestion-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    color: #8b949e;
  }

  .suggestion-text {
    flex: 1;
    font-family: 'SFMono-Regular', Consolas, monospace;
  }

  .history-query {
    color: #58a6ff;
  }

  .suggestion-hint {
    font-size: 11px;
    color: #6e7681;
    padding: 2px 6px;
    background: #21262d;
    border-radius: 4px;
  }

  .suggestion-field {
    font-size: 11px;
    color: #8b949e;
  }
</style>
