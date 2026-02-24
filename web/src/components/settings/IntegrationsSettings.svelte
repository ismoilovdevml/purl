<!--
  IntegrationsSettings Component
  Elasticsearch-compatible endpoint info and external tool integration guides

  Usage:
  <IntegrationsSettings />
-->
<script>
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';

  const origin = window.location.origin;

  let copiedEndpoint = null;
  let showGrafanaGuide = false;
  let showKibanaGuide = false;

  const endpoints = [
    {
      method: 'POST',
      path: '/api/es/_search',
      description: 'Search logs using ES Query DSL',
    },
    {
      method: 'POST',
      path: '/api/es/_msearch',
      description: 'Multi-search for dashboards',
    },
    {
      method: 'GET',
      path: '/api/es/_field_caps',
      description: 'Field capabilities for auto-discovery',
    },
  ];

  async function copyToClipboard(text) {
    try {
      await navigator.clipboard.writeText(text);
      copiedEndpoint = text;
      setTimeout(() => {
        copiedEndpoint = null;
      }, 2000);
    } catch {
      // Fallback for older browsers
      const textarea = document.createElement('textarea');
      textarea.value = text;
      textarea.style.position = 'fixed';
      textarea.style.opacity = '0';
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand('copy');
      document.body.removeChild(textarea);
      copiedEndpoint = text;
      setTimeout(() => {
        copiedEndpoint = null;
      }, 2000);
    }
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Integrations</h3>
    <p>External tool integration endpoints and status</p>
  </div>

  <!-- Elasticsearch Compatibility -->
  <Card padding="none">
    <div class="integration-header">
      <div class="integration-icon es">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M4 6h16"/>
          <path d="M4 12h16"/>
          <path d="M4 18h12"/>
          <circle cx="20" cy="18" r="2" fill="currentColor" stroke="none"/>
        </svg>
      </div>
      <div class="integration-info">
        <h4>Elasticsearch Compatibility</h4>
        <p>ES Query DSL endpoints for external tool integration</p>
      </div>
      <Badge variant="success" dot>Active</Badge>
    </div>

    <div class="integration-body">
      <p class="integration-description">
        Purl provides Elasticsearch-compatible endpoints for seamless integration with
        Kibana, Grafana, and other tools that support the Elasticsearch data source.
      </p>

      <!-- Endpoint list -->
      <div class="endpoints-list">
        <div class="endpoints-title">Available Endpoints</div>
        {#each endpoints as ep}
          <div class="endpoint-row">
            <div class="endpoint-left">
              <span class="endpoint-method" class:method-get={ep.method === 'GET'} class:method-post={ep.method === 'POST'}>
                {ep.method}
              </span>
              <code class="endpoint-path">{origin}{ep.path}</code>
            </div>
            <div class="endpoint-right">
              <span class="endpoint-desc">{ep.description}</span>
              <button
                class="copy-btn"
                on:click={() => copyToClipboard(`${origin}${ep.path}`)}
                title="Copy endpoint URL"
              >
                {#if copiedEndpoint === `${origin}${ep.path}`}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="20 6 9 17 4 12"/>
                  </svg>
                {:else}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
                    <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
                  </svg>
                {/if}
              </button>
            </div>
          </div>
        {/each}
      </div>

      <!-- Base URL -->
      <div class="base-url-row">
        <span class="base-url-label">Base URL</span>
        <code class="base-url-value">{origin}/api/es</code>
        <button
          class="copy-btn"
          on:click={() => copyToClipboard(`${origin}/api/es`)}
          title="Copy base URL"
        >
          {#if copiedEndpoint === `${origin}/api/es`}
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="20 6 9 17 4 12"/>
            </svg>
          {:else}
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
              <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
            </svg>
          {/if}
        </button>
      </div>

      <!-- Quick setup guides -->
      <div class="guides-section">
        <div class="guides-title">Quick Setup Guides</div>

        <!-- Grafana Guide -->
        <button
          class="guide-toggle"
          on:click={() => showGrafanaGuide = !showGrafanaGuide}
        >
          <svg
            class="chevron"
            class:open={showGrafanaGuide}
            width="14"
            height="14"
            viewBox="0 0 16 16"
            fill="currentColor"
          >
            <path d="M4.427 6.427l3.396 3.396a.25.25 0 00.354 0l3.396-3.396A.25.25 0 0011.396 6H4.604a.25.25 0 00-.177.427z"/>
          </svg>
          <div class="guide-icon grafana">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm-1-13h2v6h-2zm0 8h2v2h-2z"/>
            </svg>
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
              <button class="copy-btn" on:click={() => copyToClipboard(`${origin}/api/es`)} title="Copy URL">
                {#if copiedEndpoint === `${origin}/api/es`}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="20 6 9 17 4 12"/>
                  </svg>
                {:else}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
                    <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
                  </svg>
                {/if}
              </button>
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
          on:click={() => showKibanaGuide = !showKibanaGuide}
        >
          <svg
            class="chevron"
            class:open={showKibanaGuide}
            width="14"
            height="14"
            viewBox="0 0 16 16"
            fill="currentColor"
          >
            <path d="M4.427 6.427l3.396 3.396a.25.25 0 00.354 0l3.396-3.396A.25.25 0 0011.396 6H4.604a.25.25 0 00-.177.427z"/>
          </svg>
          <div class="guide-icon kibana">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
              <path d="M3 3h18v18H3V3zm2 2v14h14V5H5z"/>
              <path d="M7 7h4v10H7z"/>
              <path d="M13 7l4 5-4 5V7z"/>
            </svg>
          </div>
          <span>Kibana</span>
        </button>
        {#if showKibanaGuide}
          <div class="guide-body">
            <p class="guide-text">Add the following to your <code>kibana.yml</code> configuration:</p>
            <div class="guide-code-block">
              <code>elasticsearch.hosts: ["{origin}/api/es"]</code>
              <button class="copy-btn" on:click={() => copyToClipboard(`elasticsearch.hosts: ["${origin}/api/es"]`)} title="Copy config">
                {#if copiedEndpoint === `elasticsearch.hosts: ["${origin}/api/es"]`}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="20 6 9 17 4 12"/>
                  </svg>
                {:else}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
                    <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
                  </svg>
                {/if}
              </button>
            </div>
            <p class="guide-text">Then restart Kibana to apply the changes. Purl will appear as an Elasticsearch cluster.</p>
          </div>
        {/if}
      </div>
    </div>
  </Card>

  <!-- Grafana Integration Card -->
  <Card padding="none">
    <div class="integration-header">
      <div class="integration-icon grafana">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
          <path d="M22 12c0 5.52-4.48 10-10 10S2 17.52 2 12 6.48 2 12 2s10 4.48 10 10zm-10 8c4.41 0 8-3.59 8-8s-3.59-8-8-8-8 3.59-8 8 3.59 8 8 8zm-2-12h1.5v5H10zm3 0h1.5v5H13zm-4.5 6.5h7v1.5h-7z"/>
        </svg>
      </div>
      <div class="integration-info">
        <h4>Grafana</h4>
        <p>Dashboards and visualization</p>
      </div>
      <Badge variant="primary" size="sm">Recommended</Badge>
    </div>

    <div class="integration-body">
      <p class="integration-description">
        Connect Grafana to Purl using the Elasticsearch data source for rich log dashboards,
        alerting, and exploration.
      </p>

      <div class="config-grid">
        <div class="config-item">
          <span class="config-label">Data Source Type</span>
          <span class="config-value">Elasticsearch</span>
        </div>
        <div class="config-item">
          <span class="config-label">Connection URL</span>
          <div class="config-value-row">
            <code class="config-url">{origin}/api/es</code>
            <button
              class="copy-btn"
              on:click={() => copyToClipboard(`${origin}/api/es`)}
              title="Copy URL"
            >
              {#if copiedEndpoint === `${origin}/api/es`}
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <polyline points="20 6 9 17 4 12"/>
                </svg>
              {:else}
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
                  <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
                </svg>
              {/if}
            </button>
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
    </div>
  </Card>

  <!-- Info footer -->
  <Card padding="md">
    <h4 class="info-title">About ES Compatibility</h4>
    <p class="info-text">
      These endpoints are built into Purl and always active. They translate Elasticsearch
      Query DSL requests into ClickHouse queries, providing compatibility with tools that
      expect an Elasticsearch backend.
    </p>
    <p class="info-text">
      Supported features include <code>bool</code> queries, <code>range</code> filters,
      <code>date_histogram</code> aggregations, and <code>terms</code> aggregations.
    </p>
  </Card>
</section>

<style>
  .settings-section {
    max-width: 800px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  /* ── Section header ──────────────────────────────────────────────────────── */
  .section-header {
    margin-bottom: 8px;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  /* ── Integration header ──────────────────────────────────────────────────── */
  .integration-header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .integration-icon {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .integration-icon.es {
    background: rgba(254, 210, 51, 0.12);
    color: #fed233;
  }

  .integration-icon.grafana {
    background: rgba(255, 152, 48, 0.12);
    color: #f46800;
  }

  .integration-info {
    flex: 1;
    min-width: 0;
  }

  .integration-info h4 {
    margin: 0;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
  }

  .integration-info p {
    margin: 2px 0 0;
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
  }

  /* ── Integration body ────────────────────────────────────────────────────── */
  .integration-body {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .integration-description {
    margin: 0;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
    line-height: 1.6;
  }

  /* ── Endpoints list ──────────────────────────────────────────────────────── */
  .endpoints-list {
    display: flex;
    flex-direction: column;
    gap: 0;
    border: 1px solid var(--border-color, #21262d);
    border-radius: 6px;
    overflow: hidden;
  }

  .endpoints-title {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding: 10px 12px;
    background: var(--bg-tertiary, #21262d);
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .endpoint-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 12px;
    gap: 12px;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .endpoint-row:last-child {
    border-bottom: none;
  }

  .endpoint-left {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    flex: 1;
  }

  .endpoint-method {
    font-size: 0.6875rem;
    font-weight: 700;
    padding: 2px 6px;
    border-radius: 3px;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    flex-shrink: 0;
  }

  .endpoint-method.method-post {
    background: rgba(88, 166, 255, 0.15);
    color: var(--color-primary, #58a6ff);
  }

  .endpoint-method.method-get {
    background: rgba(63, 185, 80, 0.15);
    color: var(--color-success, #3fb950);
  }

  .endpoint-path {
    font-size: 0.8125rem;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    color: var(--text-primary, #c9d1d9);
    background: none;
    padding: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .endpoint-right {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-shrink: 0;
  }

  .endpoint-desc {
    font-size: 0.75rem;
    color: var(--text-muted, #6e7681);
    white-space: nowrap;
    display: none;
  }

  @media (min-width: 640px) {
    .endpoint-desc {
      display: inline;
    }
  }

  /* ── Copy button ─────────────────────────────────────────────────────────── */
  .copy-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 4px;
    color: var(--text-secondary, #8b949e);
    cursor: pointer;
    transition: all 0.15s ease;
    flex-shrink: 0;
  }

  .copy-btn:hover {
    background: var(--bg-hover, #30363d);
    color: var(--text-primary, #c9d1d9);
    border-color: var(--text-secondary, #8b949e);
  }

  /* ── Base URL row ────────────────────────────────────────────────────────── */
  .base-url-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 12px;
    background: var(--bg-tertiary, #21262d);
    border-radius: 6px;
  }

  .base-url-label {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-secondary, #8b949e);
    flex-shrink: 0;
  }

  .base-url-value {
    flex: 1;
    font-size: 0.8125rem;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    color: var(--color-primary, #58a6ff);
    background: none;
    padding: 0;
  }

  /* ── Guides section ──────────────────────────────────────────────────────── */
  .guides-section {
    display: flex;
    flex-direction: column;
    gap: 0;
    border: 1px solid var(--border-color, #21262d);
    border-radius: 6px;
    overflow: hidden;
  }

  .guides-title {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding: 10px 12px;
    background: var(--bg-tertiary, #21262d);
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .guide-toggle {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 10px 12px;
    background: transparent;
    border: none;
    border-bottom: 1px solid var(--border-color, #21262d);
    color: var(--text-primary, #c9d1d9);
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
    background: var(--bg-tertiary, #21262d);
  }

  .chevron {
    flex-shrink: 0;
    transition: transform 0.2s ease;
    color: var(--text-secondary, #8b949e);
  }

  .chevron.open {
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
    border-bottom: 1px solid var(--border-color, #21262d);
    background: rgba(22, 27, 34, 0.5);
  }

  .guide-steps {
    margin: 0 0 12px;
    padding-left: 20px;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
    line-height: 1.8;
  }

  .guide-steps li {
    padding-left: 4px;
  }

  .guide-steps strong {
    color: var(--text-primary, #c9d1d9);
  }

  .guide-steps code {
    background: var(--bg-tertiary, #21262d);
    padding: 1px 5px;
    border-radius: 3px;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
    color: var(--color-primary, #58a6ff);
  }

  .guide-code-row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    background: var(--bg-tertiary, #21262d);
    border-radius: 4px;
    margin: 8px 0 12px 20px;
  }

  .guide-code-row code {
    flex: 1;
    font-size: 0.8125rem;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    color: var(--color-primary, #58a6ff);
    background: none;
    padding: 0;
  }

  .guide-text {
    margin: 0 0 8px;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
    line-height: 1.6;
  }

  .guide-text code {
    background: var(--bg-tertiary, #21262d);
    padding: 1px 5px;
    border-radius: 3px;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
    color: var(--color-primary, #58a6ff);
  }

  .guide-code-block {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 12px;
    background: var(--bg-tertiary, #21262d);
    border-radius: 4px;
    margin-bottom: 12px;
  }

  .guide-code-block code {
    flex: 1;
    font-size: 0.8125rem;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    color: var(--color-primary, #58a6ff);
    background: none;
    padding: 0;
    word-break: break-all;
  }

  /* ── Config grid (Grafana card) ──────────────────────────────────────────── */
  .config-grid {
    display: flex;
    flex-direction: column;
    gap: 0;
    border: 1px solid var(--border-color, #21262d);
    border-radius: 6px;
    overflow: hidden;
  }

  .config-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 12px;
    border-bottom: 1px solid var(--border-color, #21262d);
    gap: 12px;
  }

  .config-item:last-child {
    border-bottom: none;
  }

  .config-label {
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
    flex-shrink: 0;
  }

  .config-value {
    font-size: 0.8125rem;
    color: var(--text-primary, #c9d1d9);
    text-align: right;
  }

  .config-value code {
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 3px;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
    color: var(--color-primary, #58a6ff);
  }

  .config-value-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .config-url {
    font-size: 0.8125rem;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    color: var(--color-primary, #58a6ff);
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 3px;
  }

  /* ── Info footer card ────────────────────────────────────────────────────── */
  .info-title {
    margin: 0 0 8px;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
  }

  .info-text {
    margin: 0 0 6px;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
    line-height: 1.6;
  }

  .info-text:last-child {
    margin-bottom: 0;
  }

  .info-text code {
    background: var(--bg-tertiary, #21262d);
    padding: 1px 5px;
    border-radius: 3px;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 0.75rem;
    color: var(--text-primary, #c9d1d9);
  }
</style>
