<script>
  import { createEventDispatcher, onMount } from 'svelte';
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import Select from './ui/Select.svelte';
  import Modal from './ui/Modal.svelte';
  import ConfirmDialog from './ui/ConfirmDialog.svelte';
  import EmptyState from './ui/EmptyState.svelte';
  import Icon from './ui/Icon.svelte';
  import { caretRight, plus, lock, close, save } from './ui/icons.js';
  import { isFreePlan } from '../stores/license.js';
  import { api } from '../utils/api.js';

  const dispatch = createEventDispatcher();

  let searches = [];
  let showModal = false;
  let expanded = false;
  let newName = '';
  let newQuery = '';
  let newTimeRange = '15m';
  let loadError = '';
  let saving = false;

  // Confirm dialog state
  let showDeleteConfirm = false;
  let deleteTargetId = null;

  const timeRangeOptions = [
    { value: '5m', label: '5 minutes' },
    { value: '15m', label: '15 minutes' },
    { value: '1h', label: '1 hour' },
    { value: '24h', label: '24 hours' },
    { value: '7d', label: '7 days' }
  ];

  onMount(loadSearches);

  async function loadSearches() {
    loadError = '';
    try {
      const data = await api.get('/saved-searches');
      searches = data.searches || [];
    } catch (err) {
      console.error('Failed to load saved searches:', err);
      loadError = 'Failed to load saved searches';
    }
  }

  async function saveSearch() {
    if (!newName || !newQuery) return;

    saving = true;
    try {
      await api.post('/saved-searches', {
        name: newName,
        query: newQuery,
        time_range: newTimeRange
      });
      showModal = false;
      newName = '';
      newQuery = '';
      await loadSearches();
    } catch (err) {
      console.error('Failed to save search:', err);
    } finally {
      saving = false;
    }
  }

  function requestDeleteSearch(id) {
    deleteTargetId = id;
    showDeleteConfirm = true;
  }

  async function confirmDeleteSearch() {
    if (!deleteTargetId) return;
    try {
      await api.del(`/saved-searches/${deleteTargetId}`);
      await loadSearches();
    } catch (err) {
      console.error('Failed to delete search:', err);
    }
    deleteTargetId = null;
  }

  function applySearch(search) {
    dispatch('apply', { query: search.query, timeRange: search.time_range });
  }

  export function openSaveModal(query, timeRange) {
    newQuery = query;
    newTimeRange = timeRange;
    showModal = true;
  }

  function handleHeaderKeydown(e) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      expanded = !expanded;
    }
  }
</script>

<div class="saved-searches">
  <!-- svelte-ignore a11y-no-static-element-interactions -->
  <div class="header" role="button" tabindex="0" on:click={() => expanded = !expanded} on:keydown={handleHeaderKeydown}>
    <Icon icon={caretRight} size={12} class="chevron {expanded ? 'expanded' : ''}" />
    <h3>Saved Searches</h3>
    {#if searches.length > 0}
      <span class="count">{searches.length}</span>
    {/if}
    <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
    <span class="header-actions" on:click|stopPropagation>
      <Button
        icon
        size="sm"
        variant="ghost"
        on:click={() => showModal = true}
        title="Save current search"
        aria-label="Save current search"
      >
        <Icon icon={plus} size={14} strokeWidth={2.5} />
      </Button>
    </span>
  </div>

  {#if expanded}
    <div class="content">
      {#if $isFreePlan}
        <div class="upgrade-cta">
          <Icon icon={lock} size={16} strokeWidth={2} />
          <span>Requires Pro</span>
          <a href="https://purlogs.com/pricing" target="_blank" rel="noopener">Upgrade</a>
        </div>
      {:else if loadError}
        <div class="error-state">
          <span>{loadError}</span>
          <button class="retry-btn" on:click={loadSearches}>Retry</button>
        </div>
      {:else if searches.length === 0}
        <EmptyState icon={save} title="No saved searches" size="sm">
          Save the current query to jump back to it later.
        </EmptyState>
      {:else}
        <ul>
          {#each searches as search}
            <li>
              <button class="search-item" on:click={() => applySearch(search)}>
                <span class="name">{search.name}</span>
                <span class="query">{search.query}</span>
              </button>
              <Button
                icon
                size="sm"
                variant="ghost"
                on:click={() => requestDeleteSearch(search.id)}
                title="Delete saved search"
                aria-label="Delete saved search {search.name}"
                class="delete-btn"
              >
                <Icon icon={close} size={12} strokeWidth={3} />
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
    <Button variant="success" on:click={saveSearch} loading={saving}>{saving ? 'Saving...' : 'Save'}</Button>
  </svelte:fragment>
</Modal>

<ConfirmDialog
  bind:show={showDeleteConfirm}
  title="Delete Saved Search"
  message="Are you sure you want to delete this saved search?"
  confirmText="Delete"
  variant="danger"
  onConfirm={confirmDeleteSearch}
/>

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
    user-select: none;
  }

  .header-actions {
    display: flex;
    align-items: center;
  }

  .header:hover h3 {
    color: var(--text-primary);
  }

  /* :global — the class is forwarded onto the SVG that Icon renders. */
  .header :global(.chevron) {
    color: var(--text-secondary);
    transition: transform 0.15s ease;
  }

  .header :global(.chevron.expanded) {
    transform: rotate(90deg);
  }

  h3 {
    flex: 1;
    font-size: 11px;
    text-transform: uppercase;
    color: var(--text-secondary);
    font-weight: 600;
    margin: 0;
    transition: color 0.15s;
  }

  .count {
    font-size: 10px;
    color: var(--text-muted);
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 10px;
  }

  .content {
    padding-left: 20px;
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
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    cursor: pointer;
    text-align: left;
  }

  .search-item:hover {
    border-color: var(--color-primary);
  }

  .name {
    color: var(--text-primary);
    font-size: 13px;
    font-weight: 500;
  }

  .query {
    color: var(--text-secondary);
    font-size: 11px;
    font-family: var(--font-mono);
  }

  :global(.delete-btn):hover {
    color: var(--color-error) !important;
  }

  .error-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 12px;
    color: #f85149;
    font-size: 12px;
  }

  .retry-btn {
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 4px;
    padding: 4px 12px;
    font-size: 11px;
    color: var(--text-primary);
    cursor: pointer;
  }

  .retry-btn:hover {
    background: var(--border-color);
  }

  .form-content {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .upgrade-cta {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    padding: 16px 12px;
    text-align: center;
    color: #848d97;
    font-size: 12px;
  }

  .upgrade-cta :global(svg) {
    color: #848d97;
  }

  .upgrade-cta a {
    color: #58a6ff;
    text-decoration: none;
    font-size: 11px;
  }

  .upgrade-cta a:hover {
    text-decoration: underline;
  }
</style>
