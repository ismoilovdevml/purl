<script>
  import { onMount } from 'svelte';
  import Button from '../ui/Button.svelte';
  import Modal from '../ui/Modal.svelte';
  import Icon from '../ui/Icon.svelte';
  import DashboardWidget from './DashboardWidget.svelte';
  import DashboardAddWidgetMenu from './DashboardAddWidgetMenu.svelte';
  import DashboardTemplates from './DashboardTemplates.svelte';
  import { arrowLeft } from '../ui/icons.js';
  import {
    dashboards,
    currentDashboard,
    dashboardLoading,
    fetchDashboards,
    fetchDashboard,
    createDashboard,
    updateDashboard,
    deleteDashboard,
    executeWidget,
    templates,
    fetchTemplates,
    createFromTemplate,
  } from '../../stores/dashboard.js';

  let view = $state('list'); // 'list' | 'edit'
  let newDashName = $state('');
  let showCreateModal = $state(false);
  let widgetResults = $state({});

  onMount(async () => {
    await fetchDashboards();
    await fetchTemplates();
  });

  async function handleCreateFromTemplate(templateId, name) {
    const ok = await createFromTemplate(templateId, name);
    if (ok) {
        await fetchDashboards();
    }
  }

  async function handleCreate() {
    if (!newDashName.trim()) return;
    const ok = await createDashboard({
      name: newDashName.trim(),
      widgets: [],
      layout: { columns: 2 },
    });
    if (ok) {
      showCreateModal = false;
      newDashName = '';
    }
  }

  async function openDashboard(dash) {
    const full = await fetchDashboard(dash.id);
    if (full) {
      view = 'edit';
      await refreshWidgets();
    }
  }

  function backToList() {
    view = 'list';
    currentDashboard.set(null);
    widgetResults = {};
  }

  async function addWidget(type) {
    const dash = $currentDashboard;
    if (!dash) return;
    const widget = {
      id: crypto.randomUUID(),
      type,
      title: `New ${type}`,
      query: {},
    };
    const widgets = [...(dash.widgets || []), widget];
    await updateDashboard(dash.id, { widgets });
    await fetchDashboard(dash.id);
    await refreshWidgets();
  }

  async function removeWidget(widgetId) {
    const dash = $currentDashboard;
    if (!dash) return;
    const widgets = (dash.widgets || []).filter(w => w.id !== widgetId);
    await updateDashboard(dash.id, { widgets });
    await fetchDashboard(dash.id);
    delete widgetResults[widgetId];
  }

  async function refreshWidgets() {
    const dash = $currentDashboard;
    if (!dash || !dash.widgets) return;
    const promises = dash.widgets.map(async (w) => {
      const result = await executeWidget(w);
      widgetResults[w.id] = result;
    });
    await Promise.all(promises);
    widgetResults = { ...widgetResults };
  }

  async function handleDelete() {
    const dash = $currentDashboard;
    if (!dash) return;
    if (confirm(`Delete dashboard "${dash.name}"?`)) {
      await deleteDashboard(dash.id);
      backToList();
    }
  }

</script>

<div class="dashboard-page">
  {#if view === 'list'}
    <div class="page-header">
      <h2>Dashboards</h2>
      <Button onclick={() => showCreateModal = true}>New Dashboard</Button>
    </div>

    {#if $dashboardLoading}
      <div class="loading-state">Loading dashboards...</div>
    {:else if $dashboards.length === 0}
      <div class="empty-state">
        <p>No dashboards yet. Create one to visualize your log data.</p>
        <Button onclick={() => showCreateModal = true}>Create Dashboard</Button>
      </div>
    {:else}
      <div class="dashboard-grid">
        {#each $dashboards as dash}
          <button class="dashboard-card" onclick={() => openDashboard(dash)}>
            <div class="card-title">{dash.name}</div>
            <div class="card-meta">
              {(dash.widgets || []).length} widgets
              {#if dash.description}
                <span class="card-desc">{dash.description}</span>
              {/if}
            </div>
          </button>
        {/each}
      </div>
    {/if}

    {#if $templates.length > 0}
      <DashboardTemplates templates={$templates} onpick={(tmpl) => handleCreateFromTemplate(tmpl.id, tmpl.name)} />
    {/if}

    {#if showCreateModal}
      <Modal bind:open={showCreateModal} title="Create Dashboard">
        <div class="form-group">
          <label for="dash-name">Name</label>
          <input id="dash-name" type="text" bind:value={newDashName} placeholder="My Dashboard" />
        </div>
        {#snippet footer()}
          <Button onclick={() => showCreateModal = false}>Cancel</Button>
          <Button variant="primary" onclick={handleCreate} disabled={!newDashName.trim()}>Create</Button>
        {/snippet}
      </Modal>
    {/if}

  {:else if view === 'edit' && $currentDashboard}
    <div class="page-header">
      <button class="back-btn" onclick={backToList}>
        <Icon icon={arrowLeft} size={12} strokeWidth={3} />
        Back
      </button>
      <h2>{$currentDashboard.name}</h2>
      <div class="header-actions">
        <Button onclick={refreshWidgets}>Refresh</Button>
        <DashboardAddWidgetMenu onadd={addWidget} />
        <Button variant="danger" onclick={handleDelete}>Delete</Button>
      </div>
    </div>

    <div class="widgets-grid" style="--columns: {$currentDashboard.layout?.columns || 2}">
      {#each ($currentDashboard.widgets || []) as widget (widget.id)}
        <DashboardWidget
          {widget}
          result={widgetResults[widget.id]}
          onremove={() => removeWidget(widget.id)}
        />
      {/each}

      {#if ($currentDashboard.widgets || []).length === 0}
        <div class="empty-widgets">
          <p>No widgets yet. Click "Add Widget" to get started.</p>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .dashboard-page {
    padding: 20px;
    overflow-y: auto;
    height: calc(100vh - 60px);
  }

  .page-header {
    display: flex;
    align-items: center;
    gap: 16px;
    margin-bottom: 20px;
  }

  .page-header h2 {
    font-size: 18px;
    font-weight: 600;
    color: #f0f6fc;
    flex: 1;
  }

  .header-actions {
    display: flex;
    gap: 8px;
  }

  .back-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 13px;
  }

  .back-btn:hover {
    background: #30363d;
  }

  .dashboard-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 16px;
  }

  .dashboard-card {
    padding: 20px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    cursor: pointer;
    text-align: left;
    transition: all 0.15s;
    color: #c9d1d9;
  }

  .dashboard-card:hover {
    border-color: #58a6ff;
    background: #1c2128;
  }

  .card-title {
    font-size: 15px;
    font-weight: 600;
    color: #f0f6fc;
    margin-bottom: 8px;
  }

  .card-meta {
    font-size: 12px;
    color: #8b949e;
  }

  .card-desc {
    display: block;
    margin-top: 4px;
  }

  .widgets-grid {
    display: grid;
    grid-template-columns: repeat(var(--columns, 2), 1fr);
    gap: 16px;
  }

  .empty-state, .empty-widgets {
    text-align: center;
    padding: 40px;
    color: #8b949e;
  }

  .loading-state {
    text-align: center;
    padding: 40px;
    color: #8b949e;
  }

  .form-group {
    margin-bottom: 16px;
  }

  .form-group label {
    display: block;
    font-size: 13px;
    color: #c9d1d9;
    margin-bottom: 6px;
  }

  .form-group input {
    width: 100%;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 14px;
  }

  .form-group input:focus {
    border-color: #58a6ff;
  }

  @media (max-width: 768px) {
    .widgets-grid {
      grid-template-columns: 1fr;
    }
  }
</style>
