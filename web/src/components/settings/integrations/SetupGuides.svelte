<!--
  SetupGuides
  "Quick Setup Guides" block of the Elasticsearch card: collapsible Grafana and
  Kibana instructions, each with its copyable URL / config line. Both guides
  start collapsed.
-->
<script>
  import Icon from '../../ui/Icon.svelte';
  import { caretDown, grafana, kibana } from '../../ui/icons.js';
  import CopyValueButton from './CopyValueButton.svelte';

  let {
    /** window.location.origin */
    origin,
    /** The value copied last (null once the "copied" mark expires) */
    copied = null,
    /** (text) => void */
    oncopy,
  } = $props();

  let showGrafanaGuide = $state(false);
  let showKibanaGuide = $state(false);
</script>

<div class="guides-section">
  <div class="guides-title">Quick Setup Guides</div>

  <!-- Grafana Guide -->
  <button
    class="guide-toggle"
    onclick={() => showGrafanaGuide = !showGrafanaGuide}
  >
    <Icon icon={caretDown} size={12} class="chevron {showGrafanaGuide ? 'open' : ''}" />
    <div class="guide-icon grafana">
      <Icon icon={grafana} size={16} />
    </div>
    <span>Grafana</span>
  </button>
  {#if showGrafanaGuide}
    <div class="guide-body">
      <ol class="guide-steps">
        <li>Open Grafana and navigate to <strong>Connections</strong> &rarr; <strong>Data sources</strong></li>
        <li>Click <strong>Add data source</strong> and select <strong>Elasticsearch</strong></li>
        <li>Set the URL to:</li>
      </ol>
      <div class="guide-code-row">
        <code>{origin}/api/es</code>
        <CopyValueButton
          value={`${origin}/api/es`}
          copied={copied === `${origin}/api/es`}
          title="Copy URL"
          label="Copy Grafana data source URL"
          {oncopy}
        />
      </div>
      <ol class="guide-steps" start="4">
        <li>Set <strong>Index name</strong> to <code>logs</code> and <strong>Time field</strong> to <code>timestamp</code></li>
        <li>Click <strong>Save &amp; test</strong> to verify the connection</li>
      </ol>
    </div>
  {/if}

  <!-- Kibana Guide -->
  <button
    class="guide-toggle"
    onclick={() => showKibanaGuide = !showKibanaGuide}
  >
    <Icon icon={caretDown} size={12} class="chevron {showKibanaGuide ? 'open' : ''}" />
    <div class="guide-icon kibana">
      <Icon icon={kibana} size={16} />
    </div>
    <span>Kibana</span>
  </button>
  {#if showKibanaGuide}
    <div class="guide-body">
      <p class="guide-text">Add the following to your <code>kibana.yml</code> configuration:</p>
      <div class="guide-code-block">
        <code>elasticsearch.hosts: ["{origin}/api/es"]</code>
        <CopyValueButton
          value={`elasticsearch.hosts: ["${origin}/api/es"]`}
          copied={copied === `elasticsearch.hosts: ["${origin}/api/es"]`}
          title="Copy config"
          label="Copy kibana.yml elasticsearch.hosts line"
          {oncopy}
        />
      </div>
      <p class="guide-text">Then restart Kibana to apply the changes. Purl will appear as an Elasticsearch cluster.</p>
    </div>
  {/if}
</div>

<style>
  /* ── Guides section ──────────────────────────────────────────────────────── */
  .guides-section {
    display: flex;
    flex-direction: column;
    gap: 0;
    border: 1px solid var(--border-muted);
    border-radius: 6px;
    overflow: hidden;
  }

  .guides-title {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding: 10px 12px;
    background: var(--bg-tertiary);
    border-bottom: 1px solid var(--border-muted);
  }

  .guide-toggle {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 10px 12px;
    background: transparent;
    border: none;
    border-bottom: 1px solid var(--border-muted);
    color: var(--text-primary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s ease;
    text-align: left;
  }

  .guide-toggle:last-child,
  .guide-toggle:last-of-type {
    border-bottom: none;
  }

  .guide-toggle:hover {
    background: var(--bg-tertiary);
  }

  .guide-toggle :global(.chevron) {
    flex-shrink: 0;
    transition: transform 0.2s ease;
    color: var(--text-secondary);
  }

  .guide-toggle :global(.chevron.open) {
    transform: rotate(180deg);
  }

  .guide-icon {
    width: 24px;
    height: 24px;
    border-radius: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .guide-icon.grafana {
    background: rgba(255, 152, 48, 0.12);
    color: #f46800;
  }

  .guide-icon.kibana {
    background: rgba(255, 105, 135, 0.12);
    color: #e8478b;
  }

  .guide-body {
    padding: 12px 16px 16px;
    border-bottom: 1px solid var(--border-muted);
    background: rgba(22, 27, 34, 0.5);
  }

  .guide-steps {
    margin: 0 0 12px;
    padding-left: 20px;
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.8;
  }

  .guide-steps li {
    padding-left: 4px;
  }

  .guide-steps strong {
    color: var(--text-primary);
  }

  .guide-steps code {
    background: var(--bg-tertiary);
    padding: 1px 5px;
    border-radius: 3px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--color-primary);
  }

  .guide-code-row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    background: var(--bg-tertiary);
    border-radius: 4px;
    margin: 8px 0 12px 20px;
  }

  .guide-code-row code {
    flex: 1;
    font-size: 0.8125rem;
    font-family: var(--font-mono);
    color: var(--color-primary);
    background: none;
    padding: 0;
  }

  .guide-text {
    margin: 0 0 8px;
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.6;
  }

  .guide-text code {
    background: var(--bg-tertiary);
    padding: 1px 5px;
    border-radius: 3px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--color-primary);
  }

  .guide-code-block {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 12px;
    background: var(--bg-tertiary);
    border-radius: 4px;
    margin-bottom: 12px;
  }

  .guide-code-block code {
    flex: 1;
    font-size: 0.8125rem;
    font-family: var(--font-mono);
    color: var(--color-primary);
    background: none;
    padding: 0;
    word-break: break-all;
  }
</style>
