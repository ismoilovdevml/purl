<!--
  AgentsSettings Component
  Manage Purl log collection agents

  Usage:
  <AgentsSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import ConfirmDialog from '../ui/ConfirmDialog.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { currentUser } from '../../stores/auth.js';
  import { api } from '../../utils/api.js';
  import EmptyState from '../ui/EmptyState.svelte';
  import StatTile from '../ui/StatTile.svelte';
  import { agent as agentIcon } from '../ui/icons.js';
  import AgentSetupPanel from './agents/AgentSetupPanel.svelte';
  import AgentRow from './agents/AgentRow.svelte';

  let agents = $state([]);
  let loading = $state(true);
  let error = $state('');
  let refreshing = $state(false);

  // Delete confirmation
  let showDeleteConfirm = $state(false);
  let deletingAgent = $state(null);

  const isAdmin = $derived($currentUser?.role === 'admin');
  const onlineAgents = $derived(agents.filter(a => a.status === 'online').length);
  const offlineAgents = $derived(agents.filter(a => a.status === 'offline').length);
  const serverUrl = typeof window !== 'undefined' ? window.location.origin : 'https://your-purl-server';

  onMount(() => {
    fetchAgents();
  });

  async function fetchAgents() {
    loading = agents.length === 0;
    refreshing = agents.length > 0;
    error = '';

    try {
      const data = await api.get('/agents');
      agents = data.agents || [];
    } catch (err) {
      error = err.message || 'Failed to load agents';
      toastError(error);
    } finally {
      loading = false;
      refreshing = false;
    }
  }

  function handleRefresh() {
    fetchAgents();
    toastSuccess('Agents refreshed');
  }

  async function handleDelete() {
    if (!deletingAgent) return;
    try {
      await api.del(`/agents/${deletingAgent.id}`);
      toastSuccess(`Agent "${deletingAgent.hostname}" removed`);
      showDeleteConfirm = false;
      deletingAgent = null;
      await fetchAgents();
    } catch (err) {
      toastError(err.message || 'Failed to remove agent');
    }
  }

  function confirmDelete(agent) {
    deletingAgent = agent;
    showDeleteConfirm = true;
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Agents</h3>
    <p>Manage Vector-based log collection agents running on your servers</p>
  </div>

  <!-- Stats Overview -->
  <div class="stats-row">
    {#if loading}
      <StatTile>
        <LoadingSpinner size="sm" label="Loading stats..." />
      </StatTile>
    {:else}
      <StatTile value={agents.length} label="Total Agents" />
      <StatTile value={onlineAgents} label="Online" tone={onlineAgents > 0 ? 'success' : null} />
      <StatTile value={offlineAgents} label="Offline" tone={offlineAgents > 0 ? 'warning' : null} />
    {/if}
  </div>

  <!-- Setup Instructions -->
  <AgentSetupPanel {serverUrl} />

  <!-- Agents List -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">
        Registered Agents
        {#if !loading && agents.length > 0}
          <span class="agent-count">({agents.length})</span>
        {/if}
      </span>
      <Button variant="ghost" size="sm" onclick={handleRefresh} loading={refreshing}>
        {refreshing ? 'Refreshing...' : 'Refresh'}
      </Button>
    </div>

    {#if error}
      <div class="error-box">{error}</div>
    {/if}

    {#if loading}
      <div class="empty-state">
        <LoadingSpinner size="sm" label="Loading agents..." />
      </div>
    {:else if agents.length === 0}
      <EmptyState icon={agentIcon} title="No agents registered" size="sm">
        Install the Vector-based Purl agent on your servers to start collecting logs.
        Click "Setup Instructions" above to get started.
      </EmptyState>
    {:else}
      <div class="agents-list">
        {#each agents as agent}
          <AgentRow {agent} {isAdmin} ondelete={confirmDelete} />
        {/each}
      </div>
    {/if}
  </Card>
</section>

<!--
  Every prop here used to be wrong at once, so "Remove Agent" did nothing at
  all: `show` was never passed (it defaults to false, and ConfirmDialog renders
  nothing without it), `confirmLabel` is not a prop (`confirmText` is), and
  ConfirmDialog has no createEventDispatcher, so `on:confirm`/`on:cancel` bound
  to events that are never emitted — it takes onConfirm/onCancel callbacks.
  Clicking the trash icon opened nothing and reported nothing.
-->
{#if showDeleteConfirm}
  <ConfirmDialog
    bind:show={showDeleteConfirm}
    title="Remove Agent"
    message={`Are you sure you want to remove agent "${deletingAgent?.hostname}"? The agent will need to re-register to appear again.`}
    confirmText="Remove"
    variant="danger"
    onConfirm={handleDelete}
    onCancel={() => { deletingAgent = null; }}
  />
{/if}

<style>
  .settings-section {
    max-width: 900px;
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .section-header {
    margin-bottom: 0;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-bright);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin: 0;
  }

  /* Stats row */
  .stats-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  /* Group header */
  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-muted);
  }

  .group-title {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .agent-count {
    font-weight: 400;
    text-transform: none;
    letter-spacing: 0;
  }

  /* Error */
  .error-box {
    padding: 10px 16px;
    background: rgba(248, 81, 73, 0.1);
    color: #f85149;
    font-size: 0.8125rem;
    border-bottom: 1px solid rgba(248, 81, 73, 0.2);
  }

  /* Empty state */
  .empty-state {
    padding: 40px 16px;
    text-align: center;
    color: var(--text-secondary);
    font-size: 0.875rem;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
  }

  /* Agents list */
  .agents-list {
    display: flex;
    flex-direction: column;
  }

</style>
