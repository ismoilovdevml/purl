<!--
  AIProviderStatus
  "Provider Status" card on the AI settings page: every AI provider the
  server knows, whether it is configured, which one is active and its model.
  Renders nothing once loaded if the server reports no providers.
-->
<script>
  let {
    /** GET /ai/providers is in flight */
    loading = false,
    /** [{ id, name, configured, model }] from GET /ai/providers */
    providers = [],
    /** id of the provider currently in use, or null */
    activeProvider = null,
  } = $props();
</script>

{#if loading}
  <div class="provider-status-card">
    <div class="provider-status-header">Provider Status</div>
    <div class="loading-placeholder">Loading providers…</div>
  </div>
{:else if providers.length > 0}
  <div class="provider-status-card">
    <div class="provider-status-header">Provider Status</div>
    <div class="provider-list">
      {#each providers as p}
        <div class="provider-item" class:active={p.id === activeProvider}>
          <div class="provider-left">
            <span class="status-dot" class:configured={p.configured} class:not-configured={!p.configured}></span>
            <span class="provider-name">{p.name}</span>
            {#if p.id === activeProvider}
              <span class="active-badge">Active</span>
            {/if}
          </div>
          <div class="provider-right">
            {#if p.model}
              <span class="provider-model">{p.model}</span>
            {:else if p.configured}
              <span class="provider-model default">Default model</span>
            {:else}
              <span class="provider-model not-set">Not configured</span>
            {/if}
          </div>
        </div>
      {/each}
    </div>
  </div>
{/if}

<style>
  .loading-placeholder {
    color: var(--text-secondary);
    font-size: 13px;
    padding: 20px 0;
  }

  /* Provider Status Card */
  .provider-status-card {
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    padding: 12px;
  }

  .provider-status-header {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-bottom: 10px;
  }

  .provider-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .provider-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 10px;
    border-radius: 6px;
    background: var(--bg-secondary);
    border: 1px solid transparent;
    transition: border-color 0.15s, background 0.15s;
  }

  .provider-item.active {
    border-color: rgba(88, 166, 255, 0.3);
    background: rgba(88, 166, 255, 0.05);
  }

  .provider-left {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot.configured {
    background: #3fb950;
    box-shadow: 0 0 6px rgba(63, 185, 80, 0.4);
  }

  .status-dot.not-configured {
    background: var(--text-disabled);
  }

  .provider-name {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
  }

  .active-badge {
    font-size: 10px;
    font-weight: 700;
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
    border: 1px solid rgba(88, 166, 255, 0.3);
    border-radius: 4px;
    padding: 1px 5px;
  }

  .provider-right {
    display: flex;
    align-items: center;
  }

  .provider-model {
    font-size: 12px;
    color: var(--text-secondary);
    font-family: var(--font-mono);
  }

  .provider-model.default {
    font-style: italic;
    font-family: inherit;
  }

  .provider-model.not-set {
    color: var(--text-disabled);
    font-family: inherit;
  }
</style>
