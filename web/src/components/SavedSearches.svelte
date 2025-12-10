<script>
  import { createEventDispatcher, onMount } from 'svelte';

  const dispatch = createEventDispatcher();

  let searches = [];
  let showModal = false;
  let newName = '';
  let newQuery = '';
  let newTimeRange = '15m';

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
          <button class="btn-delete" aria-label="Delete saved search" on:click|stopPropagation={() => deleteSearch(search.id)}>
            <svg width="12" height="12" viewBox="0 0 12 12">
              <path fill="currentColor" d="M9.5 3L3 9.5M3 3l6.5 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
          </button>
        </li>
      {/each}
    </ul>
  {/if}
</div>

{#if showModal}
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <div class="modal-overlay" role="dialog" aria-modal="true" tabindex="-1" on:click={() => showModal = false} on:keydown={(e) => e.key === 'Escape' && (showModal = false)}>
    <!-- svelte-ignore a11y-no-noninteractive-element-interactions -->
    <div class="modal" role="document" on:click|stopPropagation on:keydown|stopPropagation>
      <h3>Save Search</h3>
      <label>
        Name
        <input type="text" bind:value={newName} placeholder="Error logs" />
      </label>
      <label>
        Query
        <input type="text" bind:value={newQuery} placeholder="level:ERROR" />
      </label>
      <label>
        Time Range
        <select bind:value={newTimeRange}>
          <option value="5m">5 minutes</option>
          <option value="15m">15 minutes</option>
          <option value="1h">1 hour</option>
          <option value="24h">24 hours</option>
          <option value="7d">7 days</option>
        </select>
      </label>
      <div class="actions">
        <button class="btn" on:click={() => showModal = false}>Cancel</button>
        <button class="btn primary" on:click={saveSearch}>Save</button>
      </div>
    </div>
  </div>
{/if}

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

  .modal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .modal {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 20px;
    width: 400px;
  }

  .modal h3 {
    font-size: 16px;
    color: #c9d1d9;
    text-transform: none;
    margin-bottom: 16px;
  }

  label {
    display: block;
    margin-bottom: 12px;
    color: #8b949e;
    font-size: 12px;
  }

  input, select {
    width: 100%;
    margin-top: 4px;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 14px;
  }

  input:focus, select:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 16px;
  }

  .btn {
    padding: 8px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 14px;
  }

  .btn:hover {
    background: #30363d;
  }

  .btn.primary {
    background: #238636;
    border-color: #238636;
  }

  .btn.primary:hover {
    background: #2ea043;
  }
</style>
