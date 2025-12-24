<script>
  import { createEventDispatcher, onMount } from 'svelte';
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import Select from './ui/Select.svelte';
  import Modal from './ui/Modal.svelte';

  const dispatch = createEventDispatcher();

  let searches = [];
  let showModal = false;
  let expanded = false;
  let newName = '';
  let newQuery = '';
  let newTimeRange = '15m';

  const timeRangeOptions = [
    { value: '5m', label: '5 minutes' },
    { value: '15m', label: '15 minutes' },
    { value: '1h', label: '1 hour' },
    { value: '24h', label: '24 hours' },
    { value: '7d', label: '7 days' }
  ];

  const API_BASE = '/api';

  onMount(loadSearches);

  async function loadSearches() {
    try {
      const res = await fetch(`${API_BASE}/saved-searches`);
      const data = await res.json();
      searches = data.searches || [];
    } catch (err) {
      console.error('Failed to load saved searches:', err);
    }
  }

  async function saveSearch() {
    if (!newName || !newQuery) return;

    try {
      await fetch(`${API_BASE}/saved-searches`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: newName,
          query: newQuery,
          time_range: newTimeRange
        })
      });
      showModal = false;
      newName = '';
      newQuery = '';
      await loadSearches();
    } catch (err) {
      console.error('Failed to save search:', err);
    }
  }

  async function deleteSearch(id) {
    try {
      await fetch(`${API_BASE}/saved-searches/${id}`, { method: 'DELETE' });
      await loadSearches();
    } catch (err) {
      console.error('Failed to delete search:', err);
    }
  }

  function applySearch(search) {
    dispatch('apply', { query: search.query, timeRange: search.time_range });
  }

  export function openSaveModal(query, timeRange) {
    newQuery = query;
    newTimeRange = timeRange;
    showModal = true;
  }

  function handleAddClick(e) {
    e.stopPropagation();
    showModal = true;
  }
</script>

<div class="saved-searches">
  <button class="header" on:click={() => expanded = !expanded}>
    <svg class="chevron" class:expanded width="12" height="12" viewBox="0 0 12 12">
      <path fill="currentColor" d="M4 2l4 4-4 4"/>
    </svg>
    <h3>Saved Searches</h3>
    {#if searches.length > 0}
      <span class="count">{searches.length}</span>
    {/if}
    <Button icon size="sm" variant="ghost" on:click={handleAddClick} title="Save current search">
      <svg width="14" height="14" viewBox="0 0 14 14">
        <path fill="currentColor" d="M7 1v12M1 7h12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
    </Button>
  </button>

  {#if expanded}
    <div class="content">
      {#if searches.length === 0}
        <p class="empty">No saved searches</p>
      {:else}
        <ul>
          {#each searches as search}
            <li>
              <button class="search-item" on:click={() => applySearch(search)}>
                <span class="name">{search.name}</span>
                <span class="query">{search.query}</span>
              </button>
              <Button icon size="sm" variant="ghost" on:click={() => deleteSearch(search.id)} class="delete-btn">
                <svg width="12" height="12" viewBox="0 0 12 12">
                  <path fill="currentColor" d="M9.5 3L3 9.5M3 3l6.5 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                </svg>
              </Button>
            </li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}
</div>

<Modal bind:open={showModal} title="Save Search" size="sm">
  <div class="form-content">
    <Input
      label="Name"
      bind:value={newName}
      placeholder="Error logs"
      fullWidth
    />
    <Input
      label="Query"
      bind:value={newQuery}
      placeholder="level:ERROR"
      fullWidth
    />
    <Select
      label="Time Range"
      bind:value={newTimeRange}
      options={timeRangeOptions}
      fullWidth
    />
  </div>

  <svelte:fragment slot="footer">
    <Button variant="default" on:click={() => showModal = false}>Cancel</Button>
    <Button variant="success" on:click={saveSearch}>Save</Button>
  </svelte:fragment>
</Modal>

<style>
  .saved-searches {
    margin-top: 16px;
  }

  .header {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px 0;
    background: none;
    border: none;
    cursor: pointer;
    text-align: left;
  }

  .header:hover h3 {
    color: var(--text-primary, #c9d1d9);
  }

  .chevron {
    color: var(--text-secondary, #8b949e);
    transition: transform 0.15s ease;
  }

  .chevron.expanded {
    transform: rotate(90deg);
  }

  h3 {
    flex: 1;
    font-size: 11px;
    text-transform: uppercase;
    color: var(--text-secondary, #8b949e);
    font-weight: 600;
    margin: 0;
    transition: color 0.15s;
  }

  .count {
    font-size: 10px;
    color: var(--text-muted, #6e7681);
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 10px;
  }

  .content {
    padding-left: 20px;
  }

  .empty {
    color: var(--text-muted, #6e7681);
    font-size: 12px;
    margin: 0;
    padding: 8px 0;
  }

  ul {
    list-style: none;
  }

  li {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 4px;
  }

  .search-item {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    padding: 8px;
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    cursor: pointer;
    text-align: left;
  }

  .search-item:hover {
    border-color: var(--color-primary, #58a6ff);
  }

  .name {
    color: var(--text-primary, #c9d1d9);
    font-size: 13px;
    font-weight: 500;
  }

  .query {
    color: var(--text-secondary, #8b949e);
    font-size: 11px;
    font-family: var(--font-mono, monospace);
  }

  :global(.delete-btn):hover {
    color: var(--color-error, #f85149) !important;
  }

  .form-content {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
</style>
