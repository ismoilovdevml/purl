<script>
  import { createEventDispatcher } from 'svelte';
  import Badge from '../ui/Badge.svelte';
  import Button from '../ui/Button.svelte';
  import { api } from '../../utils/api.js';

  const dispatch = createEventDispatcher();

  let templates = [];
  let loading = true;
  let error = null;
  let severityFilter = 'all'; // 'all' | 'critical' | 'warning'

  async function loadTemplates() {
    loading = true;
    error = null;
    try {
      const data = await api.get('/alerts/templates');
      templates = data.templates || [];
    } catch (err) {
      console.error('Failed to load alert templates:', err);
      error = err.message;
    } finally {
      loading = false;
    }
  }

  function useTemplate(template) {
    dispatch('use-template', {
      name: template.name,
      query: template.query,
      threshold: template.threshold,
      window_minutes: template.window_minutes,
    });
  }

  $: filteredTemplates = severityFilter === 'all'
    ? templates
    : templates.filter(t => t.severity === severityFilter);

  // Load on mount
  loadTemplates();
</script>

<div class="template-gallery">
  <div class="gallery-header">
    <h4>K8s Alert Templates</h4>
    <div class="severity-filters">
      <button
        class="filter-btn"
        class:active={severityFilter === 'all'}
        on:click={() => severityFilter = 'all'}
      >
        All
      </button>
      <button
        class="filter-btn"
        class:active={severityFilter === 'critical'}
        on:click={() => severityFilter = 'critical'}
      >
        Critical
      </button>
      <button
        class="filter-btn"
        class:active={severityFilter === 'warning'}
        on:click={() => severityFilter = 'warning'}
      >
        Warning
      </button>
    </div>
  </div>

  {#if loading}
    <p class="status-msg">Loading templates...</p>
  {:else if error}
    <p class="status-msg error-msg">Failed to load templates: {error}</p>
  {:else if filteredTemplates.length === 0}
    <p class="status-msg">No templates match the selected filter.</p>
  {:else}
    <div class="template-grid">
      {#each filteredTemplates as template (template.id)}
        <div class="template-card">
          <div class="card-header">
            <span class="card-name">{template.name}</span>
            <Badge
              variant={template.severity === 'critical' ? 'error' : 'warning'}
              size="sm"
              pill
            >
              {template.severity}
            </Badge>
          </div>
          <p class="card-description">{template.description}</p>
          <code class="card-query">{template.query}</code>
          <div class="card-meta">
            <span class="meta-item">Threshold: {template.threshold}</span>
            <span class="meta-item">Window: {template.window_minutes}m</span>
          </div>
          <div class="card-actions">
            <Button size="sm" variant="primary" on:click={() => useTemplate(template)}>
              Use Template
            </Button>
          </div>
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .template-gallery {
    padding: 12px 0;
  }

  .gallery-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
    gap: 12px;
    flex-wrap: wrap;
  }

  h4 {
    margin: 0;
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary, #c9d1d9);
  }

  .severity-filters {
    display: flex;
    gap: 4px;
  }

  .filter-btn {
    padding: 4px 10px;
    font-size: 11px;
    font-weight: 500;
    background: var(--bg-tertiary, #21262d);
    color: var(--text-secondary, #8b949e);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 4px;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .filter-btn:hover {
    color: var(--text-primary, #c9d1d9);
    border-color: var(--text-secondary, #8b949e);
  }

  .filter-btn.active {
    background: var(--color-primary-bg, rgba(88, 166, 255, 0.15));
    color: var(--color-primary, #58a6ff);
    border-color: var(--color-primary, #58a6ff);
  }

  .status-msg {
    color: var(--text-muted, #848d97);
    font-size: 12px;
    margin: 16px 0;
    text-align: center;
  }

  .error-msg {
    color: var(--color-error, #f85149);
  }

  .template-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
    gap: 10px;
  }

  .template-card {
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 8px;
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    transition: border-color 0.15s ease;
  }

  .template-card:hover {
    border-color: var(--text-secondary, #8b949e);
  }

  .card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .card-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary, #c9d1d9);
  }

  .card-description {
    font-size: 12px;
    color: var(--text-secondary, #8b949e);
    margin: 0;
    line-height: 1.4;
  }

  .card-query {
    font-size: 11px;
    font-family: var(--font-mono, 'SF Mono', 'Fira Code', monospace);
    color: var(--color-primary, #58a6ff);
    background: var(--bg-primary, #0d1117);
    padding: 6px 8px;
    border-radius: 4px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    display: block;
  }

  .card-meta {
    display: flex;
    gap: 12px;
  }

  .meta-item {
    font-size: 11px;
    color: var(--text-muted, #848d97);
  }

  .card-actions {
    display: flex;
    justify-content: flex-end;
    margin-top: 4px;
  }
</style>
