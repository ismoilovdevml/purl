<!--
  AgentsSettings Component
  Manage Purl log collection agents

  Usage:
  <AgentsSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import Badge from '../ui/Badge.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import ConfirmDialog from '../ui/ConfirmDialog.svelte';
  import { formatRelativeTime } from '../../utils/format.js';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { currentUser } from '../../stores/auth.js';
  // License limits are returned by the /api/agents endpoint directly

  const API_BASE = '/api';

  let agents = [];
  let loading = true;
  let error = '';
  let refreshing = false;
  let agentLimit = { current: 0, max: 5, plan: 'free' };

  // Delete confirmation
  let showDeleteConfirm = false;
  let deletingAgent = null;

  // Setup instructions toggle
  let showSetup = false;
  let copied = false;

  $: isAdmin = $currentUser?.role === 'admin';
  $: onlineAgents = agents.filter(a => a.status === 'online').length;
  $: offlineAgents = agents.filter(a => a.status === 'offline').length;
  $: serverUrl = typeof window !== 'undefined' ? window.location.origin : 'https://your-purl-server';
  $: limitDisplay = agentLimit.max < 0 ? 'Unlimited' : `${agentLimit.current} / ${agentLimit.max}`;

  onMount(() => {
    fetchAgents();
  });

  async function fetchAgents() {
    loading = agents.length === 0;
    refreshing = agents.length > 0;
    error = '';

    try {
      const res = await fetch(`${API_BASE}/agents`);
      if (res.ok) {
        const data = await res.json();
        agents = data.agents || [];
        agentLimit = data.limit || agentLimit;
      } else {
        const data = await res.json().catch(() => ({}));
        error = data.error || 'Failed to load agents';
        toastError(error);
      }
    } catch {
      error = 'Failed to load agents';
    } finally {
      loading = false;
      refreshing = false;
    }
  }

  function handleRefresh() {
    fetchAgents();
    toastSuccess('Agents refreshed');
  }

  async function handleDelete() {
    if (!deletingAgent) return;
    try {
      const res = await fetch(`${API_BASE}/agents/${deletingAgent.id}`, { method: 'DELETE' });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data.error || 'Failed to remove agent');
      }
      toastSuccess(`Agent "${deletingAgent.hostname}" removed`);
      showDeleteConfirm = false;
      deletingAgent = null;
      await fetchAgents();
    } catch (err) {
      toastError(err.message);
    }
  }

  function confirmDelete(agent) {
    deletingAgent = agent;
    showDeleteConfirm = true;
  }

  function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(() => {
      copied = true;
      setTimeout(() => { copied = false; }, 2000);
    });
  }

  function parseLabels(labelsStr) {
    try {
      const obj = JSON.parse(labelsStr || '{}');
      return Object.entries(obj);
    } catch {
      return [];
    }
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Agents</h3>
    <p>Manage Vector-based log collection agents running on your servers</p>
  </div>

  <!-- Stats Overview -->
  <div class="stats-row">
    {#if loading}
      <div class="stat-card">
        <LoadingSpinner size="sm" label="Loading stats..." />
      </div>
    {:else}
      <div class="stat-card">
        <span class="stat-value">{agents.length}</span>
        <span class="stat-label">Total Agents</span>
      </div>
      <div class="stat-card" class:stat-success={onlineAgents > 0}>
        <span class="stat-value">{onlineAgents}</span>
        <span class="stat-label">Online</span>
      </div>
      <div class="stat-card" class:stat-warning={offlineAgents > 0}>
        <span class="stat-value">{offlineAgents}</span>
        <span class="stat-label">Offline</span>
      </div>
      <div class="stat-card">
        <span class="stat-value">{limitDisplay}</span>
        <span class="stat-label">Agent Limit ({agentLimit.plan})</span>
      </div>
    {/if}
  </div>

  <!-- Setup Instructions -->
  <Card padding="none">
    <button class="setup-toggle" on:click={() => showSetup = !showSetup}>
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        {#if showSetup}
          <polyline points="6 9 12 15 18 9"/>
        {:else}
          <polyline points="9 18 15 12 9 6"/>
        {/if}
      </svg>
      <span class="setup-title">Setup Instructions</span>
      <span class="setup-hint">How to install and configure a Purl agent</span>
    </button>

    {#if showSetup}
      <div class="setup-content">
        <p class="setup-description">
          The agent uses <strong>Vector</strong> to collect logs from <code>/var/log/</code>,
          systemd journal, and Docker containers, then ships them to your Purl server.
        </p>

        <div class="setup-step">
          <h4>1. Install via shell script</h4>
          <div class="code-block">
            <code>curl -fsSL https://purlogs.com/install.sh | sudo bash -s -- --agent -i</code>
            <button class="copy-btn" on:click={() => copyToClipboard('curl -fsSL https://purlogs.com/install.sh | sudo bash -s -- --agent -i')}>
              {copied ? 'Copied!' : 'Copy'}
            </button>
          </div>
          <div class="setup-prompts">
            <p>During installation, you'll be prompted for:</p>
            <ul>
              <li><strong>Purl Server URL</strong> — e.g. <code>{serverUrl}</code></li>
              <li><strong>API Key</strong> — from the <strong>API Keys</strong> settings page</li>
            </ul>
          </div>
        </div>

        <div class="setup-step">
          <h4>2. Or run via Docker</h4>
          <div class="code-block">
            <code>docker run -d --name purl-agent \
  -e PURL_SERVER={serverUrl} \
  -e PURL_API_KEY=YOUR_API_KEY \
  -v /var/log:/var/log:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  ismoilovdev/purl-agent:latest</code>
            <button class="copy-btn" on:click={() => copyToClipboard(`docker run -d --name purl-agent \\\n  -e PURL_SERVER=${serverUrl} \\\n  -e PURL_API_KEY=YOUR_API_KEY \\\n  -v /var/log:/var/log:ro \\\n  -v /var/run/docker.sock:/var/run/docker.sock:ro \\\n  ismoilovdev/purl-agent:latest`)}>
              {copied ? 'Copied!' : 'Copy'}
            </button>
          </div>
        </div>

        <p class="setup-note">
          The agent automatically registers with Purl on startup and sends heartbeats
          every 60 seconds. Replace <code>YOUR_API_KEY</code> with a key from the
          <strong>API Keys</strong> settings page.
        </p>
      </div>
    {/if}
  </Card>

  <!-- Agents List -->
  <Card padding="none">
    <div class="group-header">
      <span class="group-title">
        Registered Agents
        {#if !loading && agents.length > 0}
          <span class="agent-count">({agents.length})</span>
        {/if}
      </span>
      <Button variant="ghost" size="sm" on:click={handleRefresh} loading={refreshing}>
        {refreshing ? 'Refreshing...' : 'Refresh'}
      </Button>
    </div>

    {#if error}
      <div class="error-box">{error}</div>
    {/if}

    {#if loading}
      <div class="empty-state">
        <LoadingSpinner size="sm" label="Loading agents..." />
      </div>
    {:else if agents.length === 0}
      <div class="empty-state">
        <div class="empty-icon">
          <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
            <rect x="2" y="3" width="20" height="14" rx="2"/>
            <path d="M8 21h8"/>
            <path d="M12 17v4"/>
            <path d="M7 10l3-3 2 2 3-4"/>
          </svg>
        </div>
        <span class="empty-title">No agents registered</span>
        <span class="empty-hint">Install the Vector-based Purl agent on your servers to start collecting logs. Click "Setup Instructions" above to get started.</span>
      </div>
    {:else}
      <div class="agents-list">
        {#each agents as agent}
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
                <Button variant="ghost" size="sm" on:click={() => confirmDelete(agent)}>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>
                  </svg>
                </Button>
              {/if}
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </Card>
</section>

{#if showDeleteConfirm}
  <ConfirmDialog
    title="Remove Agent"
    message={`Are you sure you want to remove agent "${deletingAgent?.hostname}"? The agent will need to re-register to appear again.`}
    confirmLabel="Remove"
    variant="danger"
    on:confirm={handleDelete}
    on:cancel={() => { showDeleteConfirm = false; deletingAgent = null; }}
  />
{/if}

<style>
  .settings-section {
    max-width: 900px;
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .section-header {
    margin-bottom: 0;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  /* Stats row */
  .stats-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  .stat-card {
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #21262d);
    border-radius: 8px;
    padding: 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 120px;
  }

  .stat-card.stat-success .stat-value {
    color: #3fb950;
  }

  .stat-card.stat-warning .stat-value {
    color: #d29922;
  }

  .stat-value {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--text-primary, #f0f6fc);
    line-height: 1;
  }

  .stat-label {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  /* Setup Instructions */
  .setup-toggle {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 14px 16px;
    background: none;
    border: none;
    color: var(--text-primary, #c9d1d9);
    font-size: 0.875rem;
    cursor: pointer;
    text-align: left;
    transition: background 0.1s;
  }

  .setup-toggle:hover {
    background: var(--bg-tertiary, #21262d);
  }

  .setup-title {
    font-weight: 600;
  }

  .setup-hint {
    color: var(--text-muted, #6e7681);
    font-size: 0.8125rem;
    margin-left: auto;
  }

  .setup-content {
    padding: 16px;
    border-top: 1px solid var(--border-color, #21262d);
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .setup-step h4 {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary, #c9d1d9);
    margin: 0 0 8px;
  }

  .code-block {
    position: relative;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #21262d);
    border-radius: 6px;
    padding: 12px;
    overflow-x: auto;
  }

  .code-block code {
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.8125rem;
    color: var(--text-primary, #c9d1d9);
    white-space: pre;
  }

  .copy-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #21262d);
    color: var(--text-secondary, #8b949e);
    padding: 4px 10px;
    border-radius: 4px;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .copy-btn:hover {
    color: var(--text-primary, #c9d1d9);
    background: var(--bg-tertiary, #21262d);
  }

  .setup-note {
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
    line-height: 1.5;
  }

  .setup-description {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
    line-height: 1.5;
  }

  .setup-description code {
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 0.8125rem;
  }

  .setup-prompts {
    margin-top: 10px;
    padding: 12px 16px;
    background: rgba(210, 153, 34, 0.08);
    border: 1px solid rgba(210, 153, 34, 0.2);
    border-radius: 6px;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
  }

  .setup-prompts p {
    margin: 0 0 6px;
    color: var(--text-primary, #c9d1d9);
    font-weight: 500;
  }

  .setup-prompts ul {
    margin: 0;
    padding-left: 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .setup-prompts code {
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 0.75rem;
  }

  .setup-note code {
    background: var(--bg-tertiary, #21262d);
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 0.75rem;
  }

  /* Group header */
  .group-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .group-title {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-secondary, #8b949e);
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .agent-count {
    font-weight: 400;
    text-transform: none;
    letter-spacing: 0;
  }

  /* Error */
  .error-box {
    padding: 10px 16px;
    background: rgba(248, 81, 73, 0.1);
    color: #f85149;
    font-size: 0.8125rem;
    border-bottom: 1px solid rgba(248, 81, 73, 0.2);
  }

  /* Empty state */
  .empty-state {
    padding: 40px 16px;
    text-align: center;
    color: var(--text-secondary, #8b949e);
    font-size: 0.875rem;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
  }

  .empty-icon {
    color: var(--text-muted, #6e7681);
    margin-bottom: 4px;
  }

  .empty-title {
    font-weight: 500;
    color: var(--text-primary, #c9d1d9);
  }

  .empty-hint {
    font-size: 0.8125rem;
    color: var(--text-muted, #6e7681);
    max-width: 400px;
  }

  /* Agents list */
  .agents-list {
    display: flex;
    flex-direction: column;
  }

  .agent-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color, #21262d);
    transition: background 0.1s;
    gap: 16px;
  }

  .agent-row:hover {
    background: var(--bg-tertiary, #161b22);
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
    color: var(--text-primary, #c9d1d9);
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
    color: var(--text-muted, #6e7681);
  }

  .label-tag {
    background: var(--bg-tertiary, #21262d);
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
    background: var(--text-muted, #6e7681);
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
    color: var(--text-primary, #c9d1d9);
    font-family: 'SF Mono', 'Fira Code', monospace;
    white-space: nowrap;
  }

  .agent-stat-label {
    font-size: 0.6875rem;
    color: var(--text-muted, #6e7681);
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }
</style>
