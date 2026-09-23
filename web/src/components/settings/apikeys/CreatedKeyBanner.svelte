<!--
  CreatedKeyBanner
  One-time banner shown right after an API key is created: the full key
  (never retrievable again), a copy button and Dismiss. ApiKeysSettings owns
  the key and the copied flag.
-->
<script>
  import Button from '../../ui/Button.svelte';
  import Icon from '../../ui/Icon.svelte';
  import { check, copy, shield } from '../../ui/icons.js';

  let {
    /** { key, label } returned by POST /settings/api-keys */
    createdKey,
    /** The key was just copied to the clipboard */
    copied = false,
    /** (text) => void */
    oncopy,
    /** () => void */
    ondismiss,
  } = $props();
</script>

<div class="created-key-banner">
  <div class="created-key-header">
    <Icon icon={shield} size={16} />
    <strong>New API Key Created</strong>
  </div>
  <p class="created-key-warning">
    Copy this key now. You will not be able to see it again.
  </p>
  <div class="created-key-value">
    <code>{createdKey.key}</code>
    <button
      type="button"
      class="copy-btn"
      onclick={() => oncopy(createdKey.key)}
      title="Copy to clipboard"
      aria-label={copied ? 'API key copied to clipboard' : 'Copy API key to clipboard'}
    >
      <Icon icon={copied ? check : copy} size={16} />
    </button>
  </div>
  <Button variant="ghost" size="sm" onclick={ondismiss}>Dismiss</Button>
</div>

<style>
  .created-key-banner {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 16px;
    background: rgba(56, 139, 253, 0.1);
    border: 1px solid rgba(56, 139, 253, 0.4);
    border-radius: 8px;
  }

  .created-key-header {
    display: flex;
    align-items: center;
    gap: 8px;
    color: #58a6ff;
    font-size: 0.875rem;
  }

  .created-key-warning {
    margin: 0;
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  .created-key-value {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    overflow: hidden;
  }

  .created-key-value code {
    flex: 1;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: #3fb950;
    word-break: break-all;
    user-select: all;
  }

  .copy-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-secondary);
    cursor: pointer;
    flex-shrink: 0;
    transition: all 0.15s ease;
  }

  .copy-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
    border-color: var(--text-secondary);
  }
</style>
