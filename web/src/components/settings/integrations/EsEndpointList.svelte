<!--
  EsEndpointList
  The Elasticsearch-compatible endpoints Purl serves, each with a copy button,
  followed by the base URL row.
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
</script>

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
        <CopyValueButton
          value={`${origin}${ep.path}`}
          copied={copied === `${origin}${ep.path}`}
          title="Copy endpoint URL"
          label={`Copy ${ep.method} ${ep.path} endpoint URL`}
          {oncopy}
        />
      </div>
    </div>
  {/each}
</div>

<!-- Base URL -->
<div class="base-url-row">
  <span class="base-url-label">Base URL</span>
  <code class="base-url-value">{origin}/api/es</code>
  <CopyValueButton
    value={`${origin}/api/es`}
    copied={copied === `${origin}/api/es`}
    title="Copy base URL"
    label="Copy Elasticsearch base URL"
    {oncopy}
  />
</div>

<style>
  /* ── Endpoints list ──────────────────────────────────────────────────────── */
  .endpoints-list {
    display: flex;
    flex-direction: column;
    gap: 0;
    border: 1px solid var(--border-muted);
    border-radius: 6px;
    overflow: hidden;
  }

  .endpoints-title {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding: 10px 12px;
    background: var(--bg-tertiary);
    border-bottom: 1px solid var(--border-muted);
  }

  .endpoint-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 12px;
    gap: 12px;
    border-bottom: 1px solid var(--border-muted);
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
    font-family: var(--font-mono);
    flex-shrink: 0;
  }

  .endpoint-method.method-post {
    background: rgba(88, 166, 255, 0.15);
    color: var(--color-primary);
  }

  .endpoint-method.method-get {
    background: rgba(63, 185, 80, 0.15);
    color: var(--color-success);
  }

  .endpoint-path {
    font-size: 0.8125rem;
    font-family: var(--font-mono);
    color: var(--text-primary);
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
    color: var(--text-muted);
    white-space: nowrap;
    display: none;
  }

  @media (min-width: 640px) {
    .endpoint-desc {
      display: inline;
    }
  }

  /* ── Base URL row ────────────────────────────────────────────────────────── */
  .base-url-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 12px;
    background: var(--bg-tertiary);
    border-radius: 6px;
  }

  .base-url-label {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-secondary);
    flex-shrink: 0;
  }

  .base-url-value {
    flex: 1;
    font-size: 0.8125rem;
    font-family: var(--font-mono);
    color: var(--color-primary);
    background: none;
    padding: 0;
  }
</style>
