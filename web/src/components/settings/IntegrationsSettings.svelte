<!--
  IntegrationsSettings Component
  Elasticsearch-compatible endpoint info and external tool integration guides

  Usage:
  <IntegrationsSettings />
-->
<script>
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';
  import { pipeline, grafana } from '../ui/icons.js';
  import IntegrationCard from './integrations/IntegrationCard.svelte';
  import EsEndpointList from './integrations/EsEndpointList.svelte';
  import SetupGuides from './integrations/SetupGuides.svelte';
  import GrafanaConfigGrid from './integrations/GrafanaConfigGrid.svelte';

  const origin = window.location.origin;

  let copiedEndpoint = $state(null);

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
  <IntegrationCard
    variant="es"
    icon={pipeline}
    title="Elasticsearch Compatibility"
    subtitle="ES Query DSL endpoints for external tool integration"
  >
    {#snippet badge()}
      <Badge variant="success" dot>Active</Badge>
    {/snippet}

    <p class="integration-description">
      Purl provides Elasticsearch-compatible endpoints for seamless integration with
      Kibana, Grafana, and other tools that support the Elasticsearch data source.
    </p>

    <EsEndpointList {origin} copied={copiedEndpoint} oncopy={copyToClipboard} />

    <!-- Quick setup guides -->
    <SetupGuides {origin} copied={copiedEndpoint} oncopy={copyToClipboard} />
  </IntegrationCard>

  <!-- Grafana Integration Card -->
  <IntegrationCard
    variant="grafana"
    icon={grafana}
    title="Grafana"
    subtitle="Dashboards and visualization"
  >
    {#snippet badge()}
      <Badge variant="primary" size="sm">Recommended</Badge>
    {/snippet}

    <p class="integration-description">
      Connect Grafana to Purl using the Elasticsearch data source for rich log dashboards,
      alerting, and exploration.
    </p>

    <GrafanaConfigGrid {origin} copied={copiedEndpoint} oncopy={copyToClipboard} />
  </IntegrationCard>

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
    color: var(--text-bright);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin: 0;
  }

  .integration-description {
    margin: 0;
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.6;
  }

  /* ── Info footer card ────────────────────────────────────────────────────── */
  .info-title {
    margin: 0 0 8px;
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-bright);
  }

  .info-text {
    margin: 0 0 6px;
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.6;
  }

  .info-text:last-child {
    margin-bottom: 0;
  }

  .info-text code {
    background: var(--bg-tertiary);
    padding: 1px 5px;
    border-radius: 3px;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--text-primary);
  }
</style>
