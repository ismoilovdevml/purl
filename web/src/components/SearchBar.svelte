<script>
  import { createEventDispatcher, onMount, onDestroy } from 'svelte';
  import { levelStats, serviceStats, hostStats, connectWebSocket, isLive } from '../stores/logs.js';
  import Button from './ui/Button.svelte';
  import Icon from './ui/Icon.svelte';
  import { search as searchIcon, close, textLines, plus, dot, clock, sparkleSolid } from './ui/icons.js';
  import { debounce } from '../utils/dom.js';
  import { aiConfigured, aiSuggestions, fetchSuggestions } from '../stores/ai.js';
  import AIQueryBar from './ai/AIQueryBar.svelte';

  export let value = '';

  const dispatch = createEventDispatcher();

  // AI mode
  let aiMode = false;

  // Autocomplete state
  let showSuggestions = false;
  let suggestions = [];
  let selectedIndex = -1;
  let inputEl;
  let suggestionContainer;

  // Search history
  let searchHistory = [];
  let showHistory = false;
  const MAX_HISTORY = 10;

  // Live mode
  let ws = null;
  let unsub = null;

  // KQL operators and fields
  const OPERATORS = ['AND', 'OR', 'NOT'];
  const FIELDS = ['level', 'service', 'host', 'message', 'timestamp'];
  const META_FIELDS = [
    { field: 'meta.namespace', label: 'Namespace', group: 'Metadata' },
    { field: 'meta.pod', label: 'Pod', group: 'Metadata' },
    { field: 'meta.container', label: 'Container', group: 'Metadata' },
    { field: 'meta.node', label: 'Node', group: 'Metadata' },
    { field: 'meta.cluster', label: 'Cluster', group: 'Metadata' },
    { field: 'meta.deployment', label: 'Deployment', group: 'Metadata' },
    { field: 'meta.team', label: 'Team', group: 'Metadata' },
    { field: 'meta.environment', label: 'Environment', group: 'Metadata' },
    { field: 'meta.region', label: 'Region', group: 'Metadata' },
    { field: 'meta.version', label: 'Version', group: 'Metadata' },
    { field: 'meta.app', label: 'App', group: 'Metadata' },
  ];

  onMount(() => {
    const saved = localStorage.getItem('purl_search_history');
    if (saved) {
      searchHistory = JSON.parse(saved);
    }

    // Fetch AI suggestions if AI is already configured
    unsub = aiConfigured.subscribe(configured => {
      if (configured) {
        fetchSuggestions();
      }
    });
  });

  onDestroy(() => {
    if (unsub) unsub();
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
      } else if (event.key === 'Tab') {
        if (showSuggestions && selectedIndex >= 0) {
          event.preventDefault();
          applySuggestion(suggestions[selectedIndex]);
        }
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

  // Debounced suggestion update for better performance
  const debouncedUpdateSuggestions = debounce(updateSuggestions, 150);

  function handleInput() {
    selectedIndex = -1;
    debouncedUpdateSuggestions();
  }

  function handleFocus() {
    if (!value && (searchHistory.length > 0 || ($aiConfigured && $aiSuggestions.length > 0))) {
      showHistory = true;
    } else {
      updateSuggestions();
    }
  }

  function handleBlur(e) {
    if (!e.relatedTarget || !suggestionContainer?.contains(e.relatedTarget)) {
      showSuggestions = false;
      showHistory = false;
    }
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

      // Core field suggestions
      const fieldSuggestions = FIELDS
        .filter(f => f.toLowerCase().startsWith(tokenLower))
        .map(f => ({
          type: 'field',
          text: `${f}:`,
          display: f,
          hint: 'field'
        }));

      // Metadata field suggestions
      const metaSuggestions = META_FIELDS
        .filter(m => m.field.toLowerCase().startsWith(tokenLower) || m.label.toLowerCase().startsWith(tokenLower))
        .map(m => ({
          type: 'field',
          text: `${m.field}:`,
          display: m.field,
          hint: 'metadata',
          group: m.group
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

      suggestions = [...fieldSuggestions, ...metaSuggestions, ...opSuggestions].slice(0, 12);
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

  function applyAiSuggestion(query) {
    value = query;
    showHistory = false;
    saveToHistory(query);
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

  // Derive whether suggestions contain any metadata group items
  $: hasMetaSuggestions = suggestions.some(s => s.group === 'Metadata');
  $: hasCoreSuggestions = suggestions.some(s => !s.group && s.type === 'field');
</script>

<div class="search-bar-wrapper">
{#if aiMode && $aiConfigured}
  <div class="ai-bar-wrap">
    <button class="mode-toggle-btn active-kql" on:click={() => { aiMode = false; }} title="Switch to KQL mode">
      <Icon icon={searchIcon} size={14} strokeWidth={2.5} />
      KQL
    </button>
    <AIQueryBar on:apply={(e) => { aiMode = false; dispatch('ai-apply', e.detail); }} />
  </div>
{:else}

<div class="search-bar" role="search">
  <Button
    variant={$isLive ? 'success' : 'default'}
    on:click={toggleLive}
    title="Toggle Live Mode"
    class="live-btn"
  >
    <span class="live-indicator" class:active={$isLive}></span>
    Live
  </Button>

  <div class="search-con">
    <Icon icon={searchIcon} class="search-icon" size={16} strokeWidth={2.25} />

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
    <Button icon size="sm" variant="ghost" on:click={handleClear} title="Clear search" aria-label="Clear search" class="clear-btn">
      <Icon icon={close} size={14} strokeWidth={3} />
    </Button>
  {/if}

  <!-- Autocomplete dropdown -->
  {#if showSuggestions && suggestions.length > 0}
    <div class="suggestions" id="search-suggestions" role="listbox" aria-label="Search suggestions" bind:this={suggestionContainer}>
      {#if hasCoreSuggestions}
        {#each suggestions.filter(s => !s.group && s.type === 'field') as suggestion}
          <button
            class="suggestion-item"
            class:selected={suggestions.indexOf(suggestion) === selectedIndex}
            on:mousedown|preventDefault={() => applySuggestion(suggestion)}
            role="option"
            aria-selected={suggestions.indexOf(suggestion) === selectedIndex}
          >
            <span class="suggestion-icon">
              <Icon icon={textLines} size={12} strokeWidth={3} />
            </span>
            <span class="suggestion-text">{suggestion.display}</span>
            {#if suggestion.hint}
              <span class="suggestion-hint">{suggestion.hint}</span>
            {/if}
          </button>
        {/each}
      {/if}

      {#if hasMetaSuggestions}
        {#if hasCoreSuggestions}
          <div class="suggestion-group-divider">Metadata</div>
        {:else}
          <div class="suggestion-group-divider">Metadata</div>
        {/if}
        {#each suggestions.filter(s => s.group === 'Metadata') as suggestion}
          <button
            class="suggestion-item"
            class:selected={suggestions.indexOf(suggestion) === selectedIndex}
            on:mousedown|preventDefault={() => applySuggestion(suggestion)}
            role="option"
            aria-selected={suggestions.indexOf(suggestion) === selectedIndex}
          >
            <span class="suggestion-icon">
              <Icon icon={textLines} size={12} strokeWidth={3} />
            </span>
            <span class="suggestion-text">{suggestion.display}</span>
            <span class="suggestion-hint">{suggestion.hint}</span>
          </button>
        {/each}
      {/if}

      {#each suggestions.filter(s => s.type === 'operator') as suggestion}
        <button
          class="suggestion-item"
          class:selected={suggestions.indexOf(suggestion) === selectedIndex}
          on:mousedown|preventDefault={() => applySuggestion(suggestion)}
          role="option"
          aria-selected={suggestions.indexOf(suggestion) === selectedIndex}
        >
          <span class="suggestion-icon">
            <Icon icon={plus} size={12} strokeWidth={3} />
          </span>
          <span class="suggestion-text">{suggestion.display}</span>
          {#if suggestion.hint}
            <span class="suggestion-hint">{suggestion.hint}</span>
          {/if}
        </button>
      {/each}

      {#each suggestions.filter(s => s.type === 'value') as suggestion}
        <button
          class="suggestion-item"
          class:selected={suggestions.indexOf(suggestion) === selectedIndex}
          on:mousedown|preventDefault={() => applySuggestion(suggestion)}
          role="option"
          aria-selected={suggestions.indexOf(suggestion) === selectedIndex}
        >
          <span class="suggestion-icon">
            <Icon icon={dot} size={12} />
          </span>
          <span class="suggestion-text">{suggestion.display}</span>
          {#if suggestion.field}
            <span class="suggestion-field">{suggestion.field}</span>
          {/if}
        </button>
      {/each}
    </div>
  {/if}

  {#if showHistory && (searchHistory.length > 0 || ($aiConfigured && $aiSuggestions.length > 0))}
    <div class="suggestions history" bind:this={suggestionContainer}>
      {#if searchHistory.length > 0}
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
              <Icon icon={clock} size={12} strokeWidth={3} />
            </span>
            <span class="suggestion-text history-query">{query}</span>
          </button>
        {/each}
      {/if}

      {#if $aiConfigured && $aiSuggestions.length > 0}
        <div class="suggestion-group-divider ai-divider">
          <span class="ai-badge">AI</span>
          Suggested queries
        </div>
        {#each $aiSuggestions as query}
          <button
            class="suggestion-item"
            on:mousedown|preventDefault={() => applyAiSuggestion(query)}
          >
            <span class="suggestion-icon ai-icon">
              <Icon icon={sparkleSolid} size={12} />
            </span>
            <span class="suggestion-text">{query}</span>
            <span class="suggestion-hint ai-hint">AI</span>
          </button>
        {/each}
      {/if}
    </div>
  {/if}
  </div>

  {#if $aiConfigured}
    <button
      class="ai-toggle-btn"
      on:click={() => { aiMode = true; }}
      title="Ask AI"
    >
      <Icon icon={clock} size={14} strokeWidth={2.5} />
      Ask AI
    </button>
  {/if}
</div>
{/if}
</div>

<style>
  .search-bar-wrapper {
    flex: 1;
    max-width: 600px;
  }

  .ai-bar-wrap {
    display: flex;
    gap: 8px;
    align-items: flex-start;
  }

  .mode-toggle-btn {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 12px;
    font-weight: 500;
    padding: 6px 10px;
    border-radius: 6px;
    border: 1px solid var(--border-color);
    background: var(--bg-tertiary);
    color: var(--text-secondary);
    cursor: pointer;
    white-space: nowrap;
    flex-shrink: 0;
    transition: all 0.15s;
  }

  .mode-toggle-btn:hover {
    color: var(--text-primary);
  }

  .ai-bar-wrap > :global(.ai-query-bar) {
    flex: 1;
  }

  .ai-toggle-btn {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 12px;
    font-weight: 500;
    padding: 5px 10px;
    border-radius: 6px;
    border: 1px solid rgba(88, 166, 255, 0.3);
    background: rgba(88, 166, 255, 0.08);
    color: #58a6ff;
    cursor: pointer;
    white-space: nowrap;
    transition: all 0.15s;
    flex-shrink: 0;
  }

  .ai-toggle-btn:hover {
    background: rgba(88, 166, 255, 0.15);
  }

  .search-bar {
    flex: 1;
    max-width: 600px;
    position: relative;
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .search-con {
    flex: 1;
    position: relative;
    display: flex;
    align-items: center;
  }

  :global(.live-btn) {
    gap: 6px !important;
  }

  .live-indicator {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--text-secondary);
    transition: all 0.2s;
  }

  .live-indicator.active {
    background: var(--color-success);
    box-shadow: 0 0 6px rgba(63, 185, 80, 0.4);
  }

  /* :global — the class is forwarded onto the SVG that Icon renders. */
  .search-con :global(.search-icon) {
    position: absolute;
    left: 12px;
    color: var(--text-secondary);
    pointer-events: none;
    z-index: 1;
  }

  input {
    width: 100%;
    padding: 10px 36px;
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-primary);
    font-size: 14px;
    font-family: var(--font-mono);
  }

  input:focus {
    border-color: var(--color-primary);
    box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.15);
  }

  input::placeholder {
    color: var(--text-muted);
  }

  :global(.clear-btn) {
    position: absolute !important;
    right: 8px;
    z-index: 1;
  }

  .suggestions {
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    margin-top: 4px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 100;
    overflow: hidden;
  }

  .suggestion-group-divider {
    padding: 4px 12px;
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--text-muted);
    background: var(--bg-tertiary);
    border-top: 1px solid var(--border-color);
  }

  .history-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    border-bottom: 1px solid var(--border-color);
    font-size: 11px;
    color: var(--text-secondary);
    text-transform: uppercase;
  }

  .history-clear {
    background: none;
    border: none;
    color: var(--color-primary);
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
    color: var(--text-primary);
    text-align: left;
    cursor: pointer;
    font-size: 13px;
  }

  .suggestion-item:hover,
  .suggestion-item.selected {
    background: var(--bg-tertiary);
  }

  .suggestion-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    color: var(--text-secondary);
  }

  .suggestion-text {
    flex: 1;
    font-family: var(--font-mono);
  }

  .history-query {
    color: var(--color-primary);
  }

  .suggestion-hint {
    font-size: 11px;
    color: var(--text-muted);
    padding: 2px 6px;
    background: var(--bg-tertiary);
    border-radius: 4px;
  }

  .suggestion-field {
    font-size: 11px;
    color: var(--text-secondary);
  }

  .ai-divider {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .ai-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    font-weight: 700;
    padding: 1px 5px;
    border-radius: 3px;
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
    letter-spacing: 0.3px;
  }

  .ai-icon {
    color: #58a6ff;
  }

  .ai-hint {
    font-size: 11px;
    font-weight: 700;
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
    padding: 1px 5px;
    border-radius: 3px;
    letter-spacing: 0.3px;
  }
</style>
