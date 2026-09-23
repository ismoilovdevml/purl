<!--
  GrafanaConfigGrid
  The values to enter in Grafana's Elasticsearch data source form, with a copy
  button for the connection URL.
-->
<script>
  import CopyValueButton from './CopyValueButton.svelte';

  let {
    /** window.location.origin */
    origin,
    /** The value copied last (null once the "copied" mark expires) */
    copied = null,
    /** (text) => void */
    oncopy,
  } = $props();
</script>

<div class="config-grid">
  <div class="config-item">
    <span class="config-label">Data Source Type</span>
    <span class="config-value">Elasticsearch</span>
  </div>
  <div class="config-item">
    <span class="config-label">Connection URL</span>
    <div class="config-value-row">
      <code class="config-url">{origin}/api/es</code>
      <CopyValueButton
        value={`${origin}/api/es`}
        copied={copied === `${origin}/api/es`}
        title="Copy URL"
        label="Copy Grafana connection URL"
        {oncopy}
      />
    </div>
  </div>
  <div class="config-item">
    <span class="config-label">Index Name</span>
    <span class="config-value"><code>logs</code></span>
  </div>
  <div class="config-item">
    <span class="config-label">Time Field</span>
    <span class="config-value"><code>timestamp</code></span>
  </div>
  <div class="config-item">
    <span class="config-label">Version</span>
    <span class="config-value">7.10+</span>
  </div>
  <div class="config-item">
    <span class="config-label">Authentication</span>
    <span class="config-value">None required (session-based)</span>
  </div>
</div>

<style>
  /* ── Config grid (Grafana card) ──────────────────────────────────────────── */
  .config-grid {
    display: flex;
    flex-direction: column;
    gap: 0;
    border: 1px solid var(--border-muted);
    border-radius: 6px;
    overflow: hidden;
  }

  .config-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 12px;
    border-bottom: 1px solid var(--border-muted);
    gap: 12px;
  }

  .config-item:last-child {
    border-bottom: none;
  }

  .config-label {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    flex-shrink: 0;
  }

  .config-value {
    font-size: 0.8125rem;
    color: var(--text-primary);
    text-align: right;
  }

  .config-value code {
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 3px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--color-primary);
  }

  .config-value-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .config-url {
    font-size: 0.8125rem;
    font-family: var(--font-mono);
    color: var(--color-primary);
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 3px;
  }
</style>
