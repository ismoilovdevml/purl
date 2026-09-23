<!--
  IntegrationCard
  Shell of one integration on the Integrations page: icon, title, subtitle and
  a status badge in the header, then the body (snippet).
-->
<script>
  import Card from '../../ui/Card.svelte';
  import Icon from '../../ui/Icon.svelte';

  let {
    /** Icon colour class: 'es' | 'grafana' */
    variant,
    /** Header icon (from ui/icons.js) */
    icon,
    /** Header title */
    title,
    /** Header subtitle */
    subtitle,
    /** Status badge on the right of the header (snippet) */
    badge,
    /** Card body (snippet) */
    children,
  } = $props();
</script>

<Card padding="none">
  <div class="integration-header">
    <div class="integration-icon {variant}">
      <Icon {icon} size={24} />
    </div>
    <div class="integration-info">
      <h4>{title}</h4>
      <p>{subtitle}</p>
    </div>
    {@render badge?.()}
  </div>

  <div class="integration-body">
    {@render children?.()}
  </div>
</Card>

<style>
  .integration-header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 16px;
    border-bottom: 1px solid var(--border-muted);
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
    color: var(--text-bright);
  }

  .integration-info p {
    margin: 2px 0 0;
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .integration-body {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
</style>
