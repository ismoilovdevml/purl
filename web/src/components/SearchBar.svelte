<script>
  import { onMount, onDestroy } from 'svelte';
  import { levelStats, serviceStats, hostStats, connectWebSocket, isLive } from '../stores/logs.js';
  import Button from './ui/Button.svelte';
  import Icon from './ui/Icon.svelte';
  import { search as searchIcon, close, sparkles } from './ui/icons.js';
  import { debounce } from '../utils/dom.js';
  import { buildSuggestions, applySuggestionToQuery } from '../utils/searchSuggestions.js';
  import { aiConfigured, aiSuggestions, fetchSuggestions } from '../stores/ai.js';
  import AIQueryBar from './ai/AIQueryBar.svelte';
  import SearchDropdown from './search/SearchDropdown.svelte';

  /**
   * @type {{
   *   value?: string,
   *   onsearch?: () => void,
   *   onaiapply?: (detail: { sql: string, results: any }) => void,
   * }}
   */
  let { value = $bindable(''), onsearch, onaiapply } = $props();

  // AI mode
  let aiMode = $state(false);

  // Autocomplete state
  let showSuggestions = $state(false);
  let suggestions = $state.raw([]);
  let selectedIndex = $state(-1);
  let inputEl = $state(null);
  let suggestionContainer = $state(null);

  // Search history
  let searchHistory = $state.raw([]);
  let showHistory = $state(false);
  const MAX_HISTORY = 10;

  // Live mode
  let ws = null;
  let unsub = null;

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
        onsearch?.();
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
      onsearch?.();
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
    suggestions = buildSuggestions(value.substring(0, cursorPos), {
      level: $levelStats.map(s => s.value),
      service: $serviceStats.map(s => s.value),
      host: $hostStats.map(s => s.value),
    });
    showSuggestions = suggestions.length > 0;
  }

  function applySuggestion(suggestion) {
    const cursorPos = inputEl?.selectionStart || value.length;
    value = applySuggestionToQuery(value, cursorPos, suggestion);
    showSuggestions = false;
    selectedIndex = -1;

    // Focus back to input
    setTimeout(() => inputEl?.focus(), 0);
  }

  function applyHistory(query) {
    value = query;
    showHistory = false;
    onsearch?.();
  }

  function applyAiSuggestion(query) {
    value = query;
    showHistory = false;
    saveToHistory(query);
    onsearch?.();
  }

  function clearHistory() {
    searchHistory = [];
    localStorage.removeItem('purl_search_history');
    showHistory = false;
  }

  function handleClear() {
    value = '';
    onsearch?.();
  }
</script>

<div class="search-bar-wrapper">
{#if aiMode && $aiConfigured}
  <div class="ai-bar-wrap">
    <button class="mode-toggle-btn active-kql" onclick={() => { aiMode = false; }} title="Switch to KQL mode">
      <Icon icon={searchIcon} size={14} strokeWidth={2.5} />
      KQL
    </button>
    <AIQueryBar onapply={(detail) => { aiMode = false; onaiapply?.(detail); }} />
  </div>
{:else}

<div class="search-bar" role="search">
  <Button
    variant={$isLive ? 'success' : 'default'}
    onclick={toggleLive}
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
    onkeydown={handleKeydown}
    oninput={handleInput}
    onfocus={handleFocus}
    onblur={handleBlur}
    placeholder="Search logs... level:ERROR AND service:api*"
    autocomplete="off"
    aria-label="Search logs"
    aria-autocomplete="list"
    aria-controls={showSuggestions ? 'search-suggestions' : undefined}
  />

  {#if value}
    <Button icon size="sm" variant="ghost" onclick={handleClear} title="Clear search" aria-label="Clear search" class="clear-btn">
      <Icon icon={close} size={14} strokeWidth={3} />
    </Button>
  {/if}

  <SearchDropdown
    {showSuggestions}
    {showHistory}
    {suggestions}
    {selectedIndex}
    history={searchHistory}
    bind:container={suggestionContainer}
    onapplysuggestion={applySuggestion}
    onapplyhistory={applyHistory}
    onapplyai={applyAiSuggestion}
    onclearhistory={clearHistory}
  />
  </div>

  {#if $aiConfigured}
    <button
      class="ai-toggle-btn"
      onclick={() => { aiMode = true; }}
      title="Ask AI"
    >
      <Icon icon={sparkles} size={14} strokeWidth={2.5} />
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
</style>
