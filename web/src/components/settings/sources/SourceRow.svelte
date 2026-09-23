<!--
  SourceRow
  One ingest source in the Sources list: status dot, name, type badge, first
  seen, event count, last event and the status badge. SourcesSettings works
  out the status (it also counts active sources from it).
-->
<script>
  import Badge from '../../ui/Badge.svelte';
  import { formatCount, formatRelativeTime } from '../../../utils/format.js';

  let {
    /** Source record from GET /sources */
    source,
    /** 'active' | 'stale' | 'inactive' */
    status,
  } = $props();

  function statusLabel(status) {
    if (status === 'active') return 'Active';
    if (status === 'stale') return 'Stale';
    return 'Inactive';
  }

  function statusVariant(status) {
    if (status === 'active') return 'success';
    if (status === 'stale') return 'warning';
    return 'default';
  }

  function typeBadgeVariant(type) {
    switch (type) {
    case 'syslog':
      return 'info';
    case 'http':
      return 'primary';
    case 'otlp':
      return 'success';
    case 'filebeat':
      return 'warning';
    default:
      return 'default';
    }
  }
</script>

<div class="source-row">
  <div class="source-info">
    <div class="source-name-row">
      <span class="status-dot status-{status}" title={statusLabel(status)}></span>
      <span class="source-name">{source.name}</span>
      <Badge variant={typeBadgeVariant(source.type)} size="sm" pill>
        {source.type || 'unknown'}
      </Badge>
    </div>
    <div class="source-meta">
      {#if source.first_seen}
        <span class="meta-item">First seen {formatRelativeTime(source.first_seen)}</span>
      {/if}
    </div>
  </div>
  <div class="source-stats">
    <div class="source-stat">
      <span class="source-stat-value">{formatCount(source.events_count || 0)}</span>
      <span class="source-stat-label">events</span>
    </div>
    <div class="source-stat">
      <span class="source-stat-value">
        {source.last_event ? formatRelativeTime(source.last_event) : 'Never'}
      </span>
      <span class="source-stat-label">last event</span>
    </div>
    <div class="source-stat source-status-badge">
      <Badge variant={statusVariant(status)} size="sm" dot>
        {statusLabel(status)}
      </Badge>
    </div>
  </div>
</div>

<style>
  .source-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-muted);
    transition: background 0.1s;
    gap: 16px;
  }

  .source-row:hover {
    background: var(--bg-secondary);
  }

  .source-row:last-child {
    border-bottom: none;
  }

  .source-info {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
    flex: 1;
  }

  .source-name-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .source-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .source-meta {
    display: flex;
    align-items: center;
    gap: 12px;
    padding-left: 14px;
  }

  .meta-item {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  /* Status dot */
  .status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot.status-active {
    background: #3fb950;
    box-shadow: 0 0 4px rgba(63, 185, 80, 0.4);
  }

  .status-dot.status-stale {
    background: #d29922;
    box-shadow: 0 0 4px rgba(210, 153, 34, 0.4);
  }

  .status-dot.status-inactive {
    background: var(--text-muted);
  }

  /* Source stats */
  .source-stats {
    display: flex;
    align-items: center;
    gap: 24px;
    flex-shrink: 0;
  }

  .source-stat {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
  }

  .source-stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-family: var(--font-mono);
    white-space: nowrap;
  }

  .source-stat-label {
    font-size: 0.6875rem;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }

  .source-status-badge {
    min-width: 80px;
    align-items: flex-end;
  }
</style>
