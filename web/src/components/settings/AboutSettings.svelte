<!--
  AboutSettings Component
  About page with system info

  Usage:
  <AboutSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';
  import Button from '../ui/Button.svelte';

  const API_BASE = '/api';
  let systemInfo = null;

  onMount(() => {
    fetchSystemInfo();
  });

  async function fetchSystemInfo() {
    try {
      const res = await fetch(`${API_BASE}/health`);
      if (res.ok) {
        systemInfo = await res.json();
      }
    } catch {
      // Ignore
    }
  }

  function formatUptime(seconds) {
    if (!seconds) return '0s';
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    const parts = [];
    if (days > 0) parts.push(`${days}d`);
    if (hours > 0) parts.push(`${hours}h`);
    if (mins > 0) parts.push(`${mins}m`);
    return parts.join(' ') || '< 1m';
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>About Purl</h3>
    <p>Log aggregation and analysis platform</p>
  </div>

  <Card padding="lg" class="about-card">
    <div class="about-logo">
      <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="#58a6ff" stroke-width="1.5">
        <rect x="3" y="3" width="18" height="18" rx="2"/>
        <line x1="7" y1="8" x2="17" y2="8"/>
        <line x1="7" y1="12" x2="14" y2="12"/>
        <line x1="7" y1="16" x2="11" y2="16"/>
      </svg>
    </div>

    <h2>Purl</h2>
    <p class="about-tagline">Fast, Modern Log Aggregation</p>
    <p class="about-version">Version {systemInfo?.version || '...'}</p>

    <div class="tech-stack">
      <Badge variant="default" pill>Perl</Badge>
      <Badge variant="default" pill>ClickHouse</Badge>
      <Badge variant="default" pill>Svelte</Badge>
      <Badge variant="default" pill>Vector</Badge>
    </div>

    {#if systemInfo}
      <div class="system-status">
        <div class="status-row">
          <span>Status</span>
          <Badge variant={systemInfo.status === 'ok' ? 'success' : 'error'} size="sm">
            {systemInfo.status?.toUpperCase()}
          </Badge>
        </div>
        <div class="status-row">
          <span>ClickHouse</span>
          <span class="status-value">{systemInfo.clickhouse}</span>
        </div>
        <div class="status-row">
          <span>Uptime</span>
          <span class="status-value">{formatUptime(systemInfo.uptime_secs)}</span>
        </div>
      </div>
    {/if}

    <div class="about-links">
      <Button variant="default" on:click={() => window.open('https://github.com/ismoilovdevml/purl', '_blank')}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
          <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
        </svg>
        GitHub
      </Button>
      <Button variant="default" on:click={() => window.open('/api/metrics', '_blank')}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M18 20V10M12 20V4M6 20v-6"/>
        </svg>
        Metrics
      </Button>
    </div>
  </Card>
</section>

<style>
  .settings-section {
    max-width: 800px;
  }

  .section-header {
    margin-bottom: 24px;
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

  :global(.about-card) {
    text-align: center;
  }

  .about-logo {
    margin-bottom: 16px;
  }

  :global(.about-card) h2 {
    margin: 0;
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--text-primary, #f0f6fc);
  }

  .about-tagline {
    margin: 4px 0 0;
    font-size: 0.9375rem;
    color: var(--text-secondary, #8b949e);
  }

  .about-version {
    margin: 8px 0 16px;
    font-size: 0.8125rem;
    color: var(--text-muted, #6e7681);
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
  }

  .tech-stack {
    display: flex;
    justify-content: center;
    gap: 8px;
    margin-bottom: 24px;
  }

  .system-status {
    background: var(--bg-primary, #0d1117);
    border-radius: 8px;
    padding: 12px 16px;
    margin-bottom: 24px;
    text-align: left;
  }

  .status-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 6px 0;
    font-size: 0.8125rem;
  }

  .status-row span:first-child {
    color: var(--text-secondary, #8b949e);
  }

  .status-value {
    color: var(--text-primary, #f0f6fc);
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
  }

  .about-links {
    display: flex;
    justify-content: center;
    gap: 12px;
  }
</style>
