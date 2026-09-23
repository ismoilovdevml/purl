<!--
  SsoMetadataCard
  The SP metadata URL the identity provider should be pointed at, with a copy
  button. Renders nothing until an SP Entity ID is set.
-->
<script>
  import Card from '../../ui/Card.svelte';
  import Icon from '../../ui/Icon.svelte';
  import { check, copy } from '../../ui/icons.js';

  let {
    /** Current SP Entity ID; the card is hidden while it is empty */
    spEntityId = '',
  } = $props();

  let copied = $state(false);

  const metadataUrl = $derived(
    spEntityId
      ? `${window.location.origin}/api/auth/saml/metadata`
      : ''
  );

  function copyMetadataUrl() {
    if (!metadataUrl) return;
    navigator.clipboard.writeText(metadataUrl).then(() => {
      copied = true;
      setTimeout(() => { copied = false; }, 2000);
    });
  }
</script>

{#if metadataUrl}
  <Card padding="md">
    <div class="card-section-title">SP Metadata</div>
    <div class="metadata-row">
      <code class="metadata-url">{metadataUrl}</code>
      <button
        type="button"
        class="copy-btn"
        onclick={copyMetadataUrl}
        title="Copy metadata URL"
        aria-label="Copy SP metadata URL"
      >
        {#if copied}
          <Icon icon={check} size={14} strokeWidth={2.5} />
        {:else}
          <Icon icon={copy} size={14} strokeWidth={2.5} />
        {/if}
      </button>
    </div>
    <p class="metadata-hint">Provide this URL to your identity provider for automatic SP configuration.</p>
  </Card>
{/if}

<style>
  .card-section-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    margin-bottom: 14px;
  }

  .metadata-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
  }

  .metadata-url {
    flex: 1;
    min-width: 0;
    padding: 8px 12px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    font-size: 0.8125rem;
    color: var(--text-primary);
    font-family: var(--font-mono);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .copy-btn {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-secondary);
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .copy-btn:hover {
    color: var(--text-primary);
    border-color: var(--text-secondary);
  }

  .metadata-hint {
    margin: 0;
    font-size: 0.75rem;
    color: var(--text-muted);
    line-height: 1.5;
  }
</style>
