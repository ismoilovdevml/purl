<!--
  DashboardTemplates
  The "Templates" section of the dashboard list: one card per template;
  clicking a card creates a dashboard from it (DashboardPage does that).
-->
<script>
  let {
    /** [{ id, name, description }] */
    templates,
    /** (template) => void */
    onpick,
  } = $props();
</script>

<div class="templates-section">
  <h3>Templates</h3>
  <div class="template-grid">
    {#each templates as tmpl}
      <button class="template-card" onclick={() => onpick(tmpl)}>
        <div class="template-name">{tmpl.name}</div>
        <div class="template-desc">{tmpl.description}</div>
      </button>
    {/each}
  </div>
</div>

<style>
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
</style>
