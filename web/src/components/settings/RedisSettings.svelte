<script>
  import { onMount } from 'svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import Icon from '../ui/Icon.svelte';
  import { info } from '../ui/icons.js';

  let config = {
    url:  '',
    mode: 'auto',
  };
  let fromEnv = {};
  let loading = false;

  onMount(async () => {
    await loadConfig();
  });

  async function loadConfig() {
    loading = true;
    try {
      const data = await api.get('/settings/redis');
      config   = { ...config, ...data.config };
      fromEnv  = data.from_env || {};
    } catch {
      toastError('Failed to load Redis settings');
    } finally {
      loading = false;
    }
  }

  async function save() {
    loading = true;
    try {
      await api.put('/settings/redis', config);
      toastSuccess('Redis settings saved');
      await loadConfig();
    } catch (err) {
      toastError(err.message || 'Failed to save settings');
    } finally {
      loading = false;
    }
  }


</script>

<div class="redis-settings">
  <div class="settings-header">
    <div>
      <h3 class="settings-title">Redis / Broadcast Settings</h3>
      <p class="settings-desc">Configure Redis connection and broadcast mode for multi-server WebSocket support.</p>
    </div>
  </div>

  {#if loading && !config.mode}
    <div class="loading-placeholder">Loading…</div>
  {:else}
    <div class="form">

      <!-- Broadcast Mode -->
      <div class="field">
        <div class="field-label">
          Broadcast Mode
          {#if fromEnv.mode}<span class="env-badge">ENV</span>{/if}
        </div>
        <div class="radio-group">
          <label class="radio-item" class:disabled={fromEnv.mode}>
            <input type="radio" bind:group={config.mode} value="auto" disabled={fromEnv.mode} />
            <span class="radio-label">
              <strong>Auto</strong>
              <span class="radio-hint">Use Redis if available, otherwise local</span>
            </span>
          </label>
          <label class="radio-item" class:disabled={fromEnv.mode}>
            <input type="radio" bind:group={config.mode} value="local" disabled={fromEnv.mode} />
            <span class="radio-label">
              <strong>Local</strong>
              <span class="radio-hint">Single-server mode, no Redis required</span>
            </span>
          </label>
          <label class="radio-item" class:disabled={fromEnv.mode}>
            <input type="radio" bind:group={config.mode} value="redis" disabled={fromEnv.mode} />
            <span class="radio-label">
              <strong>Redis</strong>
              <span class="radio-hint">Force Redis for multi-server WebSocket broadcasting</span>
            </span>
          </label>
        </div>
      </div>

      <!-- Redis URL (only when mode = redis) -->
      {#if config.mode === 'redis' || config.mode === 'auto'}
        <div class="field">
          <label for="redis-url" class="field-label">
            Redis URL
            {#if fromEnv.url}<span class="env-badge">ENV</span>{/if}
            {#if config.mode === 'auto'}<span class="optional">(optional)</span>{/if}
          </label>
          <input
            id="redis-url"
            type="text"
            bind:value={config.url}
            disabled={fromEnv.url}
            placeholder="redis://localhost:6379"
            class="field-input"
          />
          <p class="field-hint">
            {#if config.mode === 'auto'}
              Optional. If provided, Redis will be used when available.
            {:else}
              Required for Redis broadcast mode. Format: redis://host:port
            {/if}
          </p>
        </div>
      {/if}

      <div class="actions">
        <button class="btn-save" on:click={save} disabled={loading}>
          {loading ? 'Saving…' : 'Save'}
        </button>
      </div>

      <!-- Info box -->
      <div class="info-box">
        <div class="info-row">
          <Icon icon={info} size={14} strokeWidth={2.5} />
          <span>Redis is required when running multiple Purl instances behind a load balancer.</span>
        </div>
        <div class="info-row">
          <Icon icon={info} size={14} strokeWidth={2.5} />
          <span>Changes take effect on next Purl restart or WebSocket reconnect.</span>
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  .redis-settings {
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .settings-header { display: flex; align-items: flex-start; }

  .settings-title {
    font-size: 16px;
    font-weight: 600;
    color: var(--text-primary);
    margin: 0 0 4px;
  }

  .settings-desc {
    font-size: 13px;
    color: var(--text-secondary);
    margin: 0;
  }

  .loading-placeholder {
    color: var(--text-secondary);
    font-size: 13px;
    padding: 20px 0;
  }

  .form {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .field-label {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .optional { font-weight: 400; color: var(--text-secondary); font-size: 12px; }

  .env-badge {
    font-size: 10px;
    font-weight: 700;
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
    border: 1px solid rgba(210, 153, 34, 0.3);
    border-radius: 4px;
    padding: 1px 5px;
  }

  .radio-group {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .radio-item {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 10px 12px;
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    cursor: pointer;
    transition: border-color 0.15s;
  }

  .radio-item:has(input:checked) {
    border-color: #58a6ff;
    background: rgba(88, 166, 255, 0.05);
  }

  .radio-item.disabled { opacity: 0.6; cursor: not-allowed; }

  .radio-item input[type="radio"] {
    margin-top: 2px;
    accent-color: #58a6ff;
    flex-shrink: 0;
  }

  .radio-label {
    display: flex;
    flex-direction: column;
    gap: 2px;
    font-size: 13px;
    color: var(--text-primary);
  }

  .radio-hint {
    font-size: 12px;
    color: var(--text-secondary);
    font-weight: 400;
  }

  .field-input {
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-primary);
    font-size: 13px;
    padding: 7px 10px;
    width: 100%;
    box-sizing: border-box;
    transition: border-color 0.15s;
  }

  /* Border-color is the resting cue; the global :focus-visible ring stays. */
  .field-input:focus { border-color: #58a6ff; }
  .field-input:disabled { opacity: 0.6; cursor: not-allowed; }

  .field-hint {
    font-size: 12px;
    color: var(--text-secondary);
    margin: 0;
  }

  .actions {
    display: flex;
    gap: 8px;
    justify-content: flex-end;
  }

  .btn-save {
    background: #238636;
    color: #fff;
    border: none;
    border-radius: 6px;
    padding: 7px 20px;
    font-size: 13px;
    cursor: pointer;
    transition: background 0.15s;
  }

  .btn-save:hover:not(:disabled) { background: #2ea043; }
  .btn-save:disabled { opacity: 0.5; cursor: not-allowed; }

  .info-box {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px;
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
  }

  .info-row {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    font-size: 12px;
    color: var(--text-secondary);
  }

  .info-row :global(svg) { margin-top: 1px; }
</style>
