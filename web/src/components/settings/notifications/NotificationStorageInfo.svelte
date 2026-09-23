<!--
  NotificationStorageInfo
  Footer card of the notifications page: where the settings are stored and
  that environment variables win over them.
-->
<script>
  import Card from '../../ui/Card.svelte';
</script>

<Card padding="md" class="auth-info-card">
  <h4>Settings Storage</h4>
  <p>Notification settings are saved to <code>/app/config/settings.json</code> on the server.</p>
  <p>Environment variables take precedence over UI settings and cannot be modified here.</p>
</Card>

<style>
  :global(.auth-info-card) {
    margin-top: 24px;
  }

  :global(.auth-info-card) h4 {
    margin: 0 0 8px;
    font-size: 0.875rem;
    color: var(--text-bright);
  }

  :global(.auth-info-card) p {
    margin: 8px 0;
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  :global(.auth-info-card) code {
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 4px;
    font-family: var(--font-mono);
  }
</style>
