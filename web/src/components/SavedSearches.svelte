<script>
  import { createEventDispatcher, onMount } from 'svelte';
  import { fetchSavedSearches, createSavedSearch, deleteSavedSearch } from '../lib/api.js';
  import Modal from './ui/Modal.svelte';
  import Button from './ui/Button.svelte';

  const dispatch = createEventDispatcher();

  let searches = [];
  let showModal = false;
  let newName = '';
  let newQuery = '';
  let newTimeRange = '15m';

  onMount(loadSearches);

  async function loadSearches() {
    try {
      const data = await fetchSavedSearches();
      searches = data.searches || [];
    } catch (err) {
      console.error('Failed to load saved searches:', err);
    }
  }

  async function saveSearch() {
    if (!newName || !newQuery) return;

    try {
      await createSavedSearch({
        name: newName,
        query: newQuery,
        time_range: newTimeRange
      });
      closeModal();
      await loadSearches();
    } catch (err) {
      console.error('Failed to save search:', err);
    }
  }

  async function handleDelete(id) {
    try {
      await deleteSavedSearch(id);
      await loadSearches();
    } catch (err) {
      console.error('Failed to delete search:', err);
    }
  }

  function applySearch(search) {
    dispatch('apply', { query: search.query, timeRange: search.time_range });
  }

  function closeModal() {
    showModal = false;
    newName = '';
    newQuery = '';
  }

  export function openSaveModal(query, timeRange) {
    newQuery = query;
    newTimeRange = timeRange;
    showModal = true;
  }
</script>

<div class="saved-searches">
  <div class="header">
    <h3>Saved Searches</h3>
    <button class="btn-icon" on:click={() => showModal = true} title="Save current search">
      <svg width="14" height="14" viewBox="0 0 14 14">
        <path fill="currentColor" d="M7 1v12M1 7h12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
    </button>
  </div>

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
          <button class="btn-delete" aria-label="Delete saved search" on:click|stopPropagation={() => handleDelete(search.id)}>
            <svg width="12" height="12" viewBox="0 0 12 12">
              <path fill="currentColor" d="M9.5 3L3 9.5M3 3l6.5 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          </button>
        </li>
      {/each}
    </ul>
  {/if}
</div>

<Modal show={showModal} title="Save Search" on:close={closeModal}>
  <div class="form-group">
    <label for="search-name">Name</label>
    <input id="search-name" type="text" bind:value={newName} placeholder="Error logs" />
  </div>
  <div class="form-group">
    <label for="search-query">Query</label>
    <input id="search-query" type="text" bind:value={newQuery} placeholder="level:ERROR" />
  </div>
  <div class="form-group">
    <label for="search-time-range">Time Range</label>
    <select id="search-time-range" bind:value={newTimeRange}>
      <option value="5m">5 minutes</option>
      <option value="15m">15 minutes</option>
      <option value="1h">1 hour</option>
      <option value="24h">24 hours</option>
      <option value="7d">7 days</option>
    </select>
  </div>
  <svelte:fragment slot="footer">
    <Button on:click={closeModal}>Cancel</Button>
    <Button variant="primary" on:click={saveSearch}>Save</Button>
  </svelte:fragment>
</Modal>

<style>
  .saved-searches {
    margin-top: 24px;
  }

  .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }

  h3 {
    font-size: 12px;
    text-transform: uppercase;
    color: #8b949e;
    font-weight: 600;
  }

  .btn-icon {
    padding: 4px;
    background: none;
    border: none;
    color: #8b949e;
    cursor: pointer;
    border-radius: 4px;
  }

  .btn-icon:hover {
    color: #c9d1d9;
    background: #30363d;
  }

  .empty {
    color: #6e7681;
    font-size: 13px;
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
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    cursor: pointer;
    text-align: left;
  }

  .search-item:hover {
    border-color: #58a6ff;
  }

  .name {
    color: #c9d1d9;
    font-size: 13px;
    font-weight: 500;
  }

  .query {
    color: #8b949e;
    font-size: 11px;
    font-family: monospace;
  }

  .btn-delete {
    padding: 4px;
    background: none;
    border: none;
    color: #6e7681;
    cursor: pointer;
    border-radius: 4px;
  }

  .btn-delete:hover {
    color: #f85149;
    background: rgba(248, 81, 73, 0.1);
  }

  /* Form styles */
  .form-group {
    margin-bottom: 16px;
  }

  .form-group label {
    display: block;
    margin-bottom: 6px;
    color: #8b949e;
    font-size: 12px;
    font-weight: 500;
  }

  .form-group input,
  .form-group select {
    width: 100%;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 14px;
  }

  .form-group input:focus,
  .form-group select:focus {
    outline: none;
    border-color: #58a6ff;
  }
</style>
