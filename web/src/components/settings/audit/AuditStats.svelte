<!--
  AuditStats
  The 24h overview above the audit log: total events, distinct actions,
  failures, and the top five action/status pairs.
-->
<script>
  import Card from '../../ui/Card.svelte';
  import StatTile from '../../ui/StatTile.svelte';
  import LoadingSpinner from '../../ui/LoadingSpinner.svelte';
  import Icon from '../../ui/Icon.svelte';
  import { check, close } from '../../ui/icons.js';
  import { actionColor } from '../../../utils/audit.js';

  let {
    /** [{ action, status, count }] from GET /audit/stats */
    stats = [],
    /** Stats are still loading */
    loading = true,
  } = $props();

  // Compute total events from stats
  const totalEvents24h = $derived(stats.reduce((sum, s) => sum + (s.count || 0), 0));
  const uniqueActions = $derived([...new Set(stats.map(s => s.action))]);
  const failureCount = $derived(stats.filter(s => s.status === 'failure').reduce((sum, s) => sum + (s.count || 0), 0));
</script>

<!-- 24h Stats Overview -->
<div class="stats-row">
  {#if loading}
    <Card padding="md">
      <LoadingSpinner size="sm" label="Loading stats..." />
    </Card>
  {:else}
    <StatTile value={totalEvents24h} label="Events (24h)" />
    <StatTile value={uniqueActions.length} label="Action Types" />
    <StatTile value={failureCount} label="Failures (24h)" tone={failureCount > 0 ? 'danger' : null} />

    {#if stats.length > 0}
      <StatTile label="Top Actions" wide>
        <div class="breakdown-list">
          {#each stats.slice(0, 5) as entry}
            <div class="breakdown-item">
              <span class="breakdown-action {actionColor(entry.action)}">{entry.action}</span>
              <span class="breakdown-count">{entry.count}</span>
              <span class="breakdown-status status-{entry.status}">
                <Icon
                  icon={entry.status === 'success' ? check : close}
                  size={12}
                  strokeWidth={3}
                  label={entry.status === 'success' ? 'Succeeded' : 'Failed'}
                />
              </span>
            </div>
          {/each}
        </div>
      </StatTile>
    {/if}
  {/if}
</div>

<style>
  /* Stats row */
  .stats-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  .breakdown-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-top: 8px;
  }

  .breakdown-item {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.75rem;
  }

  .breakdown-action {
    flex: 1;
    color: var(--text-secondary);
  }

  .breakdown-count {
    font-weight: 600;
    color: var(--text-primary);
    min-width: 28px;
    text-align: right;
  }

  .breakdown-status {
    display: inline-flex;
    align-items: center;
  }

  .status-success {
    color: #3fb950;
  }

  .status-failure {
    color: #f85149;
  }

  /* Same palette as the action badges in AuditLogTable */
  .action-success {
    background: rgba(63, 185, 80, 0.15);
    color: #3fb950;
  }

  .action-danger {
    background: rgba(248, 81, 73, 0.15);
    color: #f85149;
  }

  .action-warning {
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
  }
</style>
