<!--
  SearchDropdown
  The panel that opens under the search input. Two variants share its styles:
  the KQL autocomplete listbox (fields, metadata fields, operators, values)
  and, when the input is empty, the recent-searches / AI-suggested-queries
  menu. SearchBar owns all state (what is shown, which item is highlighted,
  the history list); this component only renders it and reports picks.
  Items fire on mousedown with preventDefault so the input keeps focus.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { textLines, plus, dot, clock, sparkleSolid } from '../ui/icons.js';
  import { preventDefault } from '../../utils/dom.js';
  import { aiConfigured, aiSuggestions } from '../../stores/ai.js';

  let {
    /** Show the autocomplete listbox */
    showSuggestions = false,
    /** Show the history / AI-suggestions menu */
    showHistory = false,
    /** Autocomplete items from buildSuggestions() */
    suggestions = [],
    /** Keyboard-highlighted index into `suggestions` (-1 = none) */
    selectedIndex = -1,
    /** Recent queries, newest first */
    history = [],
    /** The open panel element — SearchBar's blur handler checks focus against it */
    container = $bindable(null),
    /** (suggestion) => void */
    onapplysuggestion,
    /** (query: string) => void */
    onapplyhistory,
    /** (query: string) => void */
    onapplyai,
    /** () => void */
    onclearhistory,
  } = $props();

  // Derive whether suggestions contain any metadata group items
  const hasMetaSuggestions = $derived(suggestions.some(s => s.group === 'Metadata'));
  const hasCoreSuggestions = $derived(suggestions.some(s => !s.group && s.type === 'field'));
</script>

{#snippet suggestionItem(suggestion, icon, iconProps, trailing)}
  <button
    class="suggestion-item"
    class:selected={suggestions.indexOf(suggestion) === selectedIndex}
    onmousedown={preventDefault(() => onapplysuggestion?.(suggestion))}
    role="option"
    aria-selected={suggestions.indexOf(suggestion) === selectedIndex}
  >
    <span class="suggestion-icon">
      <Icon {icon} size={12} {...iconProps} />
    </span>
    <span class="suggestion-text">{suggestion.display}</span>
    {@render trailing(suggestion)}
  </button>
{/snippet}

{#snippet hintTrailing(suggestion)}
  {#if suggestion.hint}
    <span class="suggestion-hint">{suggestion.hint}</span>
  {/if}
{/snippet}

{#snippet fieldTrailing(suggestion)}
  {#if suggestion.field}
    <span class="suggestion-field">{suggestion.field}</span>
  {/if}
{/snippet}

<!-- Autocomplete dropdown -->
{#if showSuggestions && suggestions.length > 0}
  <div class="suggestions" id="search-suggestions" role="listbox" aria-label="Search suggestions" bind:this={container}>
    {#if hasCoreSuggestions}
      {#each suggestions.filter(s => !s.group && s.type === 'field') as suggestion}
        {@render suggestionItem(suggestion, textLines, { strokeWidth: 3 }, hintTrailing)}
      {/each}
    {/if}

    {#if hasMetaSuggestions}
      <div class="suggestion-group-divider">Metadata</div>
      {#each suggestions.filter(s => s.group === 'Metadata') as suggestion}
        {@render suggestionItem(suggestion, textLines, { strokeWidth: 3 }, hintTrailing)}
      {/each}
    {/if}

    {#each suggestions.filter(s => s.type === 'operator') as suggestion}
      {@render suggestionItem(suggestion, plus, { strokeWidth: 3 }, hintTrailing)}
    {/each}

    {#each suggestions.filter(s => s.type === 'value') as suggestion}
      {@render suggestionItem(suggestion, dot, {}, fieldTrailing)}
    {/each}
  </div>
{/if}

{#if showHistory && (history.length > 0 || ($aiConfigured && $aiSuggestions.length > 0))}
  <div class="suggestions history" bind:this={container}>
    {#if history.length > 0}
      <div class="history-header">
        <span>Recent searches</span>
        <button class="history-clear" onmousedown={preventDefault(() => onclearhistory?.())}>Clear</button>
      </div>
      {#each history as query}
        <button
          class="suggestion-item"
          onmousedown={preventDefault(() => onapplyhistory?.(query))}
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
          onmousedown={preventDefault(() => onapplyai?.(query))}
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

<style>
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
