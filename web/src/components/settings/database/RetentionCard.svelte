<!--
  RetentionCard
  "Data Retention" card on the Database settings page: the retention period
  (locked when PURL_RETENTION_DAYS pins it) with Apply, the last save result
  and the log volume stats. DatabaseSettings owns the state and requests.
-->
<script>
  import Input from '../../ui/Input.svelte';
  import Button from '../../ui/Button.svelte';
  import Card from '../../ui/Card.svelte';
  import Badge from '../../ui/Badge.svelte';
  import { formatBytes, formatNumber, formatRelativeTime } from '../../../utils/format.js';

  let {
    /** Retention period in days */
    days = $bindable(),
    /** retention.days is pinned by the environment */
    fromEnv = false,
    /** PUT /settings/retention in flight */
    saving = false,
    /** { success, text } from the last save, or null */
    message = null,
    /** GET /config/retention result, or null */
    stats = null,
    /** () => void */
    onsave,
  } = $props();
</script>

<Card padding="none" class="retention-card">
  <div class="group-header">
    <span class="group-title">Data Retention</span>
    {#if fromEnv}
      <Badge variant="warning" size="sm">From Environment</Badge>
    {/if}
  </div>

  <div class="setting-item">
    <div class="setting-info">
      <span class="setting-label">Retention Period</span>
      <span class="setting-hint">How long to keep log data (ClickHouse TTL)</span>
    </div>
    <div class="retention-control">
      <Input
        type="number"
        min={1}
        max={365}
        bind:value={days}
        size="sm"
        envLocked={fromEnv}
      />
      <span class="unit">days</span>
      <Button
        variant="success"
        size="sm"
        onclick={onsave}
        loading={saving}
        disabled={fromEnv}
      >
        {saving ? 'Saving...' : 'Apply'}
      </Button>
    </div>
  </div>

  {#if message}
    <div class="result-box" class:success={message.success}>
      {message.text}
    </div>
  {/if}

  {#if stats}
    <div class="stats-grid">
      <div class="stat-card">
        <span class="stat-value">{formatNumber(stats.total_logs || 0)}</span>
        <span class="stat-label">Total Logs</span>
      </div>
      <div class="stat-card">
        <span class="stat-value">{formatBytes((stats.db_size_mb || 0) * 1024 * 1024)}</span>
        <span class="stat-label">Database Size</span>
      </div>
      <div class="stat-card">
        <span class="stat-value">{stats.oldest_log ? formatRelativeTime(stats.oldest_log) : 'N/A'}</span>
        <span class="stat-label">Oldest Log</span>
      </div>
      <div class="stat-card">
        <span class="stat-value">{stats.newest_log ? formatRelativeTime(stats.newest_log) : 'N/A'}</span>
        <span class="stat-label">Newest Log</span>
      </div>
    </div>
  {/if}
</Card>

<style>
  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    background: rgba(33, 38, 45, 0.3);
    border-bottom: 1px solid var(--border-muted);
  }

  .group-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .result-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 16px;
    font-size: 0.8125rem;
    color: var(--color-error);
    background: rgba(248, 81, 73, 0.1);
    border-top: 1px solid var(--border-muted);
  }

  .result-box.success {
    color: var(--color-success);
    background: rgba(63, 185, 80, 0.1);
  }

  .setting-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-muted);
  }

  .setting-item:last-child {
    border-bottom: none;
  }

  .setting-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .setting-label {
    font-size: 0.875rem;
    color: var(--text-primary);
  }

  .setting-hint {
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .retention-control {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .retention-control .unit {
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  :global(.retention-card) {
    margin-top: 24px;
  }

  .stats-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
    padding: 16px;
    background: var(--bg-primary);
    border-top: 1px solid var(--border-muted);
  }

  .stat-card {
    text-align: center;
    padding: 12px 8px;
    background: var(--bg-secondary);
    border-radius: 6px;
  }

  .stat-value {
    display: block;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-bright);
    font-family: var(--font-mono);
  }

  .stat-label {
    display: block;
    font-size: 0.6875rem;
    color: var(--text-secondary);
    margin-top: 4px;
  }
</style>
