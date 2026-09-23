<!--
  AgentRow
  One registered agent in the Agents list: status dot, hostname, badges,
  meta (IP, version, API key, labels), heartbeat/registration times and —
  for admins — the delete button.
-->
<script>
  import Button from '../../ui/Button.svelte';
  import Badge from '../../ui/Badge.svelte';
  import Icon from '../../ui/Icon.svelte';
  import { trash } from '../../ui/icons.js';
  import { formatRelativeTime } from '../../../utils/format.js';

  let {
    /** Agent record from GET /agents */
    agent,
    /** Show the delete button */
    isAdmin = false,
    /** (agent) => void */
    ondelete,
  } = $props();

  function parseLabels(labelsStr) {
    try {
      const obj = JSON.parse(labelsStr || '{}');
      return Object.entries(obj);
    } catch {
      return [];
    }
  }
</script>

<div class="agent-row">
  <div class="agent-info">
    <div class="agent-name-row">
      <span class="status-dot status-{agent.status}" title={agent.status === 'online' ? 'Online' : 'Offline'}></span>
      <span class="agent-name">{agent.hostname}</span>
      <Badge variant={agent.status === 'online' ? 'success' : 'default'} size="sm" dot>
        {agent.status === 'online' ? 'Online' : 'Offline'}
      </Badge>
      {#if agent.os}
        <Badge variant="info" size="sm" pill>{agent.os}</Badge>
      {/if}
    </div>
    <div class="agent-meta">
      {#if agent.ip_address}
        <span class="meta-item">{agent.ip_address}</span>
      {/if}
      {#if agent.agent_version}
        <span class="meta-item">v{agent.agent_version}</span>
      {/if}
      {#if agent.api_key_label}
        <span class="meta-item">Key: {agent.api_key_label}</span>
      {/if}
      {#each parseLabels(agent.labels) as [key, value]}
        <span class="meta-item label-tag">{key}: {value}</span>
      {/each}
    </div>
  </div>
  <div class="agent-stats">
    <div class="agent-stat">
      <span class="agent-stat-value">
        {agent.last_heartbeat_at ? formatRelativeTime(agent.last_heartbeat_at) : 'Never'}
      </span>
      <span class="agent-stat-label">last heartbeat</span>
    </div>
    <div class="agent-stat">
      <span class="agent-stat-value">
        {agent.registered_at ? formatRelativeTime(agent.registered_at) : 'Unknown'}
      </span>
      <span class="agent-stat-label">registered</span>
    </div>
    {#if isAdmin}
      <Button
        variant="ghost"
        size="sm"
        aria-label="Delete agent {agent.hostname}"
        onclick={() => ondelete(agent)}
      >
        <Icon icon={trash} size={14} strokeWidth={2.5} />
      </Button>
    {/if}
  </div>
</div>

<style>
  .agent-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-muted);
    transition: background 0.1s;
    gap: 16px;
  }

  .agent-row:hover {
    background: var(--bg-secondary);
  }

  .agent-row:last-child {
    border-bottom: none;
  }

  .agent-info {
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 0;
    flex: 1;
  }

  .agent-name-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .agent-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .agent-meta {
    display: flex;
    align-items: center;
    gap: 12px;
    padding-left: 14px;
    flex-wrap: wrap;
  }

  .meta-item {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .label-tag {
    background: var(--bg-tertiary);
    padding: 1px 6px;
    border-radius: 3px;
  }

  /* Status dot */
  .status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot.status-online {
    background: #3fb950;
    box-shadow: 0 0 4px rgba(63, 185, 80, 0.4);
  }

  .status-dot.status-offline {
    background: var(--text-muted);
  }

  /* Agent stats */
  .agent-stats {
    display: flex;
    align-items: center;
    gap: 24px;
    flex-shrink: 0;
  }

  .agent-stat {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
  }

  .agent-stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-family: var(--font-mono);
    white-space: nowrap;
  }

  .agent-stat-label {
    font-size: 0.6875rem;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }
</style>
