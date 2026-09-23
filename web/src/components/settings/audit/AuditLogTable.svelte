<!--
  AuditLogTable
  The audit event rows (time, actor, action, resource, status, IP). A row with
  details expands on click / Enter / Space; AuditSettings owns which rows are
  expanded.
-->
<script>
  import Icon from '../../ui/Icon.svelte';
  import { caretRight } from '../../ui/icons.js';
  import { actionColor } from '../../../utils/audit.js';

  let {
    /** Audit events of the current page */
    logs = [],
    /** Set of expanded event ids */
    expandedRows = new Set(),
    /** (logId) => void — toggle one row's details */
    ontoggle,
  } = $props();

  function formatDate(dateStr) {
    if (!dateStr) return '—';
    try {
      const d = new Date(dateStr);
      const now = new Date();
      const diffMs = now - d;
      const diffMin = Math.floor(diffMs / 60000);
      const diffHr = Math.floor(diffMs / 3600000);

      if (diffMin < 1) return 'Just now';
      if (diffMin < 60) return `${diffMin}m ago`;
      if (diffHr < 24) return `${diffHr}h ago`;

      return d.toLocaleString('en-US', {
        month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit',
        hour12: false
      });
    } catch {
      return dateStr;
    }
  }

  function formatFullDate(dateStr) {
    if (!dateStr) return '';
    try {
      return new Date(dateStr).toLocaleString('en-US', {
        year: 'numeric', month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit', second: '2-digit',
        hour12: false
      });
    } catch {
      return dateStr;
    }
  }

  function statusIcon(status) {
    return status === 'success' ? 'success' : 'failure';
  }
</script>

<div class="table-scroll-wrapper">
  <div class="log-table">
    <div class="table-header">
      <span class="col-time">Time (UTC)</span>
      <span class="col-actor">Actor</span>
      <span class="col-action">Action</span>
      <span class="col-resource">Resource</span>
      <span class="col-status">Status</span>
      <span class="col-ip">IP Address</span>
    </div>
    <div class="table-body">
      {#each logs as log}
        <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
        <div
          class="log-row"
          class:log-row-expandable={log.details}
          onclick={() => log.details && ontoggle(log.id)}
          onkeydown={(e) => (e.key === 'Enter' || e.key === ' ') && log.details && ontoggle(log.id)}
          role={log.details ? 'button' : undefined}
          tabindex={log.details ? 0 : undefined}
        >
          <span class="col-time" title={formatFullDate(log.timestamp) + ' (UTC)'}>
            {formatDate(log.timestamp)}
          </span>
          <span class="col-actor">
            <span class="actor-name">{log.actor || '—'}</span>
          </span>
          <span class="col-action">
            <span class="action-badge {actionColor(log.action)}">
              {log.action || '—'}
            </span>
          </span>
          <span class="col-resource">
            {#if log.resource_type}
              <span class="resource-type">{log.resource_type}</span>
              {#if log.resource_id}
                <span class="resource-id">{log.resource_id}</span>
              {/if}
            {:else}
              <span class="text-muted">—</span>
            {/if}
          </span>
          <span class="col-status">
            <span class="status-dot status-{statusIcon(log.status)}"></span>
            {log.status || '—'}
          </span>
          <span class="col-ip">
            <span class="ip-text">{log.ip_address || '—'}</span>
            {#if log.details}
              <Icon
                icon={caretRight}
                size={10}
                class="expand-icon {expandedRows.has(log.id) ? 'expanded' : ''}"
              />
            {/if}
          </span>
        </div>
        {#if log.details && expandedRows.has(log.id)}
          <div class="log-details">
            <span class="details-text">{log.details}</span>
          </div>
        {/if}
      {/each}
    </div>
  </div>
</div>

<style>
  /* Responsive table wrapper */
  .table-scroll-wrapper {
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }

  /* Table */
  .log-table {
    display: flex;
    flex-direction: column;
    min-width: 640px;
  }

  .table-header {
    display: grid;
    grid-template-columns: 100px 100px 140px 1fr 80px 120px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--border-color);
    font-size: 0.7rem;
    font-weight: 600;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .table-body {
    display: flex;
    flex-direction: column;
  }

  .log-row {
    display: grid;
    grid-template-columns: 100px 100px 140px 1fr 80px 120px;
    padding: 8px 16px;
    border-bottom: 1px solid var(--border-muted);
    font-size: 0.8125rem;
    align-items: center;
    transition: background 0.1s;
  }

  .log-row:hover {
    background: var(--bg-secondary);
  }

  .log-row-expandable {
    cursor: pointer;
  }

  .log-row:last-child {
    border-bottom: none;
  }

  .col-time {
    color: var(--text-secondary);
    font-size: 0.75rem;
    cursor: default;
  }

  .actor-name {
    color: var(--text-primary);
    font-weight: 500;
  }

  .action-badge {
    display: inline-block;
    padding: 1px 6px;
    border-radius: 4px;
    font-size: 0.7rem;
    font-weight: 500;
    font-family: var(--font-mono);
    background: rgba(110, 118, 129, 0.15);
    color: var(--text-secondary);
  }

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

  .col-resource {
    display: flex;
    align-items: center;
    gap: 6px;
    overflow: hidden;
  }

  .resource-type {
    font-size: 0.7rem;
    font-weight: 500;
    padding: 1px 6px;
    border-radius: 4px;
    background: rgba(56, 139, 253, 0.1);
    color: #58a6ff;
    white-space: nowrap;
  }

  .resource-id {
    font-size: 0.75rem;
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .col-status {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 0.75rem;
    color: var(--text-secondary);
  }

  .status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot.status-success {
    background: #3fb950;
  }

  .status-dot.status-failure {
    background: #f85149;
  }

  .ip-text {
    font-size: 0.75rem;
    color: var(--text-muted);
    font-family: var(--font-mono);
  }

  .col-ip {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  /* :global() because the svg is rendered by <Icon>, outside this component's
     scoped-class rewriting. */
  .col-ip :global(.expand-icon) {
    color: var(--text-muted);
    transition: transform 0.15s ease;
    margin-left: auto;
  }

  .col-ip :global(.expand-icon.expanded) {
    transform: rotate(90deg);
  }

  .text-muted {
    color: var(--text-muted);
  }

  .log-details {
    padding: 4px 16px 8px 116px;
    border-bottom: 1px solid var(--border-muted);
  }

  .details-text {
    font-size: 0.75rem;
    color: var(--text-muted);
    font-style: italic;
  }
</style>
