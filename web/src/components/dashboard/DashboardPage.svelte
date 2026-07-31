<script>
  import { onMount } from 'svelte';
  import Button from '../ui/Button.svelte';
  import Modal from '../ui/Modal.svelte';
  import Icon from '../ui/Icon.svelte';
  import { hash, activity, table, terminal, arrowLeft, close } from '../ui/icons.js';
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

  let view = 'list'; // 'list' | 'edit'
  let newDashName = '';
  let showCreateModal = false;
  let widgetResults = {};

  // Widget type options. `icon` holds the imported glyph itself, not a name —
  // that is what keeps icons.js tree-shakeable.
  const widgetTypes = [
    { value: 'counter', label: 'Counter', icon: hash },
    { value: 'chart', label: 'Time Chart', icon: activity },
    { value: 'table', label: 'Top Values', icon: table },
    { value: 'log_stream', label: 'Log Stream', icon: terminal },
  ];

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

  function formatNumber(n) {
    if (n === undefined || n === null) return '0';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n.toLocaleString();
  }
</script>

<div class="dashboard-page">
  {#if view === 'list'}
    <div class="page-header">
      <h2>Dashboards</h2>
      <Button on:click={() => showCreateModal = true}>New Dashboard</Button>
    </div>

    {#if $dashboardLoading}
      <div class="loading-state">Loading dashboards...</div>
    {:else if $dashboards.length === 0}
      <div class="empty-state">
        <p>No dashboards yet. Create one to visualize your log data.</p>
        <Button on:click={() => showCreateModal = true}>Create Dashboard</Button>
      </div>
    {:else}
      <div class="dashboard-grid">
        {#each $dashboards as dash}
          <button class="dashboard-card" on:click={() => openDashboard(dash)}>
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
      <div class="templates-section">
        <h3>Templates</h3>
        <div class="template-grid">
          {#each $templates as tmpl}
            <button class="template-card" on:click={() => handleCreateFromTemplate(tmpl.id, tmpl.name)}>
              <div class="template-name">{tmpl.name}</div>
              <div class="template-desc">{tmpl.description}</div>
            </button>
          {/each}
        </div>
      </div>
    {/if}

    {#if showCreateModal}
      <Modal bind:open={showCreateModal} title="Create Dashboard">
        <div class="form-group">
          <label for="dash-name">Name</label>
          <input id="dash-name" type="text" bind:value={newDashName} placeholder="My Dashboard" />
        </div>
        <svelte:fragment slot="footer">
          <Button on:click={() => showCreateModal = false}>Cancel</Button>
          <Button variant="primary" on:click={handleCreate} disabled={!newDashName.trim()}>Create</Button>
        </svelte:fragment>
      </Modal>
    {/if}

  {:else if view === 'edit' && $currentDashboard}
    <div class="page-header">
      <button class="back-btn" on:click={backToList}>
        <Icon icon={arrowLeft} size={12} strokeWidth={3} />
        Back
      </button>
      <h2>{$currentDashboard.name}</h2>
      <div class="header-actions">
        <Button on:click={refreshWidgets}>Refresh</Button>
        <div class="add-widget-dropdown">
          <Button>+ Add Widget</Button>
          <div class="widget-menu">
            {#each widgetTypes as wt}
              <button on:click={() => addWidget(wt.value)}>
                <span class="widget-icon"><Icon icon={wt.icon} size={14} strokeWidth={2.5} /></span>
                {wt.label}
              </button>
            {/each}
          </div>
        </div>
        <Button variant="danger" on:click={handleDelete}>Delete</Button>
      </div>
    </div>

    <div class="widgets-grid" style="--columns: {$currentDashboard.layout?.columns || 2}">
      {#each ($currentDashboard.widgets || []) as widget (widget.id)}
        <div class="widget-card">
          <div class="widget-header">
            <span class="widget-title">{widget.title}</span>
            <button
              class="widget-close"
              on:click={() => removeWidget(widget.id)}
              aria-label="Remove widget {widget.title}"
            >
              <Icon icon={close} size={12} strokeWidth={3} />
            </button>
          </div>
          <div class="widget-body">
            {#if !widgetResults[widget.id]}
              <div class="widget-loading">Loading...</div>
            {:else if widgetResults[widget.id].error}
              <div class="widget-error">{widgetResults[widget.id].error}</div>
            {:else if widget.type === 'counter'}
              <div class="counter-value">{formatNumber(widgetResults[widget.id].value)}</div>
            {:else if widget.type === 'chart'}
              <div class="chart-placeholder">
                {#each (widgetResults[widget.id].data || []).slice(-20) as point}
                  <div class="chart-bar" style="height: {Math.max(2, (point.count / Math.max(...(widgetResults[widget.id].data || []).map(p => p.count || 1))) * 100)}%"></div>
                {/each}
              </div>
            {:else if widget.type === 'table'}
              <table class="widget-table">
                <tbody>
                  {#each (widgetResults[widget.id].data || []).slice(0, 10) as row}
                    <tr>
                      <td>{row.value}</td>
                      <td class="count">{formatNumber(row.count)}</td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            {:else if widget.type === 'log_stream'}
              <div class="log-stream">
                {#each (widgetResults[widget.id].logs || []).slice(0, 10) as log}
                  <div class="log-line">
                    <span class="log-level level-{(log.level || '').toLowerCase()}">{log.level}</span>
                    <span class="log-msg">{log.message}</span>
                  </div>
                {/each}
              </div>
            {/if}
          </div>
        </div>
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

  .widget-card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
    min-height: 200px;
  }

  .widget-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    border-bottom: 1px solid #21262d;
  }

  .widget-title {
    font-size: 13px;
    font-weight: 600;
    color: #c9d1d9;
  }

  .widget-close {
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    color: #8b949e;
    cursor: pointer;
    padding: 2px 4px;
    line-height: 1;
  }

  .widget-close:hover {
    color: #f85149;
  }

  .widget-body {
    padding: 14px;
  }

  .widget-loading, .widget-error {
    color: #8b949e;
    font-size: 13px;
    text-align: center;
    padding: 20px;
  }

  .widget-error {
    color: #f85149;
  }

  .counter-value {
    font-size: 36px;
    font-weight: 700;
    color: #58a6ff;
    text-align: center;
    padding: 20px;
  }

  .chart-placeholder {
    display: flex;
    align-items: flex-end;
    gap: 2px;
    height: 120px;
    padding-top: 10px;
  }

  .chart-bar {
    flex: 1;
    background: #58a6ff;
    border-radius: 2px 2px 0 0;
    min-height: 2px;
    transition: height 0.3s;
  }

  .widget-table {
    width: 100%;
    font-size: 13px;
  }

  .widget-table td {
    padding: 6px 8px;
    border-bottom: 1px solid #21262d;
  }

  .widget-table .count {
    text-align: right;
    color: #58a6ff;
    font-weight: 500;
  }

  .log-stream {
    max-height: 200px;
    overflow-y: auto;
  }

  .log-line {
    display: flex;
    gap: 8px;
    padding: 3px 0;
    font-size: 12px;
    font-family: var(--font-mono);
  }

  .log-level {
    flex-shrink: 0;
    width: 56px;
    text-align: center;
    font-size: 10px;
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
  }

  .level-error, .level-critical, .level-emergency {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
  }

  .level-warning {
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
  }

  .level-info, .level-notice {
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
  }

  .level-debug, .level-trace {
    background: rgba(139, 148, 158, 0.15);
    color: #8b949e;
  }

  .log-msg {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: #c9d1d9;
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

  .add-widget-dropdown {
    position: relative;
  }

  .add-widget-dropdown:hover .widget-menu {
    display: block;
  }

  .widget-menu {
    display: none;
    position: absolute;
    top: 100%;
    right: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.4);
    z-index: 200;
    min-width: 160px;
    padding: 4px 0;
  }

  .widget-menu button {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px 14px;
    background: none;
    border: none;
    color: #c9d1d9;
    font-size: 13px;
    cursor: pointer;
    text-align: left;
  }

  .widget-menu button:hover {
    background: #21262d;
  }

  .widget-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    color: #58a6ff;
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

  .templates-section {
    margin-top: 24px;
  }

  .templates-section h3 {
    font-size: 14px;
    font-weight: 600;
    color: #8b949e;
    margin-bottom: 12px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .template-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 12px;
  }

  .template-card {
    padding: 16px;
    background: #0d1117;
    border: 1px dashed #30363d;
    border-radius: 8px;
    cursor: pointer;
    text-align: left;
    color: #c9d1d9;
    transition: all 0.15s;
  }

  .template-card:hover {
    border-color: #58a6ff;
    border-style: solid;
    background: #161b22;
  }

  .template-name {
    font-size: 14px;
    font-weight: 600;
    color: #58a6ff;
    margin-bottom: 6px;
  }

  .template-desc {
    font-size: 12px;
    color: #8b949e;
  }

  @media (max-width: 768px) {
    .widgets-grid {
      grid-template-columns: 1fr;
    }
  }
</style>
