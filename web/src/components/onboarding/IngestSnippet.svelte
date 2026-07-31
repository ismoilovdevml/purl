<!--
  IngestSnippet

  The canonical "send your first log line to Purl" curl command, with a copy
  button. Shared so the command exists in exactly one place: it is shown both
  in Settings -> API Keys (as usage documentation) and in the logs empty state
  (as onboarding for an instance that has never received anything).

  Usage:
  <IngestSnippet />
  <IngestSnippet apiKey={key.token} />   <!- substitutes a real key ->

  The command is built from `window.location.origin`, so it is copy-pasteable
  against whatever host the dashboard is being served from.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { check, copy } from '../ui/icons.js';
  import { copyToClipboard } from '../../utils/dom.js';

  /** Substituted into the header when known; otherwise a placeholder is shown. */
  export let apiKey = null;

  let copied = false;
  let copyTimer = null;

  $: origin = typeof window !== 'undefined' ? window.location.origin : 'https://your-purl-server';
  $: key = apiKey || 'YOUR_API_KEY';
  $: command = [
    `curl -X POST ${origin}/api/v1/logs \\`,
    `  -H 'X-API-Key: ${key}' \\`,
    "  -H 'Content-Type: application/json' \\",
    '  -d \'{"level": "info", "message": "Hello Purl"}\'',
  ];

  async function handleCopy() {
    const ok = await copyToClipboard(command.join('\n'));
    if (!ok) return;
    copied = true;
    clearTimeout(copyTimer);
    copyTimer = setTimeout(() => { copied = false; }, 2000);
  }
</script>

<div class="ingest-snippet">
  <pre><code>{command.join('\n')}</code></pre>
  <button
    type="button"
    class="copy-btn"
    on:click={handleCopy}
    aria-label={copied ? 'Command copied' : 'Copy command'}
  >
    <Icon icon={copied ? check : copy} size={14} />
    <span>{copied ? 'Copied' : 'Copy'}</span>
  </button>
</div>

<style>
  .ingest-snippet {
    position: relative;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--border-radius, 6px);
    padding: 12px 14px;
  }

  pre {
    margin: 0;
    overflow-x: auto;
  }

  code {
    display: block;
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
    font-size: 12px;
    line-height: 1.7;
    color: var(--text-secondary, #8b949e);
    white-space: pre;
  }

  .copy-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 8px;
    font-size: 11px;
    font-family: inherit;
    color: var(--text-secondary, #8b949e);
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--border-radius-sm, 4px);
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .copy-btn:hover {
    color: var(--text-primary, #c9d1d9);
    border-color: var(--border-hover, #484f58);
  }
</style>
