<!--
  AgentSetupPanel
  Collapsible "Setup Instructions" card on the Agents settings page: the
  install-script and Docker one-liners with copy buttons, plus what the
  installer will prompt for. Owns only its own open/copied UI state.
-->
<script>
  import Card from '../../ui/Card.svelte';
  import Icon from '../../ui/Icon.svelte';
  import { caretDown, caretRight } from '../../ui/icons.js';

  let {
    /** Origin of this Purl server, shown in the snippets */
    serverUrl,
  } = $props();

  let showSetup = $state(false);
  let copied = $state(false);

  function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(() => {
      copied = true;
      setTimeout(() => { copied = false; }, 2000);
    });
  }
</script>

<Card padding="none">
  <button class="setup-toggle" onclick={() => showSetup = !showSetup} aria-expanded={showSetup}>
    <Icon icon={showSetup ? caretDown : caretRight} size={12} />
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
          <button class="copy-btn" onclick={() => copyToClipboard('curl -fsSL https://purlogs.com/install.sh | sudo bash -s -- --agent -i')}>
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
          <button class="copy-btn" onclick={() => copyToClipboard(`docker run -d --name purl-agent \\\n  -e PURL_SERVER=${serverUrl} \\\n  -e PURL_API_KEY=YOUR_API_KEY \\\n  -v /var/log:/var/log:ro \\\n  -v /var/run/docker.sock:/var/run/docker.sock:ro \\\n  ismoilovdev/purl-agent:latest`)}>
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

<style>
  /* Setup Instructions */
  .setup-toggle {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 14px 16px;
    background: none;
    border: none;
    color: var(--text-primary);
    font-size: 0.875rem;
    cursor: pointer;
    text-align: left;
    transition: background 0.1s;
  }

  .setup-toggle:hover {
    background: var(--bg-tertiary);
  }

  .setup-title {
    font-weight: 600;
  }

  .setup-hint {
    color: var(--text-muted);
    font-size: 0.8125rem;
    margin-left: auto;
  }

  .setup-content {
    padding: 16px;
    border-top: 1px solid var(--border-muted);
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .setup-step h4 {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    margin: 0 0 8px;
  }

  .code-block {
    position: relative;
    background: var(--bg-primary);
    border: 1px solid var(--border-muted);
    border-radius: 6px;
    padding: 12px;
    overflow-x: auto;
  }

  .code-block code {
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--text-primary);
    white-space: pre;
  }

  .copy-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-muted);
    color: var(--text-secondary);
    padding: 4px 10px;
    border-radius: 4px;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .copy-btn:hover {
    color: var(--text-primary);
    background: var(--bg-tertiary);
  }

  .setup-note {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    margin: 0;
    line-height: 1.5;
  }

  .setup-description {
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin: 0;
    line-height: 1.5;
  }

  .setup-description code {
    background: var(--bg-tertiary);
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
    color: var(--text-secondary);
  }

  .setup-prompts p {
    margin: 0 0 6px;
    color: var(--text-primary);
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
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 0.75rem;
  }

  .setup-note code {
    background: var(--bg-tertiary);
    padding: 2px 6px;
    border-radius: 3px;
    font-size: 0.75rem;
  }

</style>
