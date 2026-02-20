<script>
  import { onMount } from 'svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';

  let config = {
    provider: 'openai',
    api_key: '',
    model: '',
    base_url: '',
    enabled: true,
  };
  let fromEnv = {};
  let loading = false;
  let testing = false;
  let testResult = null;
  let showKey = false;

  const PROVIDERS = [
    {
      id: 'openai', label: 'OpenAI', requiresKey: true, requiresUrl: false, placeholder: 'sk-...',
      models: ['gpt-4.1-mini-2025-04-14', 'gpt-4.1-2025-04-14', 'gpt-5-2025-08-07', 'o3-2025-04-16', 'o4-mini-2025-04-16'],
    },
    {
      id: 'anthropic', label: 'Anthropic', requiresKey: true, requiresUrl: false, placeholder: 'sk-ant-...',
      models: ['claude-haiku-4-5-20251001', 'claude-sonnet-4-6', 'claude-opus-4-6'],
    },
    {
      id: 'gemini', label: 'Google Gemini', requiresKey: true, requiresUrl: false, placeholder: 'AIza...',
      models: ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.5-flash-lite'],
    },
    {
      id: 'ollama', label: 'Ollama (Self-hosted)', requiresKey: false, requiresUrl: true, placeholder: '',
      models: ['llama3.3', 'qwen2.5', 'deepseek-r1', 'gemma3', 'phi4', 'mistral', 'deepseek-v3'],
    },
  ];

  $: currentProvider = PROVIDERS.find(p => p.id === config.provider) || PROVIDERS[0];

  onMount(async () => {
    await loadConfig();
  });

  async function loadConfig() {
    loading = true;
    try {
      const res = await fetch('/api/settings/ai');
      if (res.ok) {
        const data = await res.json();
        config = { ...config, ...data.config };
        fromEnv = data.from_env || {};
      }
    } catch {
      toastError('Failed to load AI settings');
    } finally {
      loading = false;
    }
  }

  async function save() {
    loading = true;
    testResult = null;
    try {
      const payload = { ...config };
      // Don't send masked key back
      if (payload.api_key === '********') {
        delete payload.api_key;
      }

      const res = await fetch('/api/settings/ai', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });

      const data = await res.json();
      if (res.ok) {
        toastSuccess('AI settings saved');
        await loadConfig();
      } else {
        toastError(data.error || 'Failed to save settings');
      }
    } catch {
      toastError('Failed to save settings');
    } finally {
      loading = false;
    }
  }

  async function testConnection() {
    testing = true;
    testResult = null;
    try {
      const res = await fetch('/api/settings/ai/test', { method: 'POST' });
      const data = await res.json();
      testResult = data;
    } catch {
      testResult = { status: 'error', message: 'Connection failed' };
    } finally {
      testing = false;
    }
  }

  function clearModel() {
    config.model = '';
  }
</script>

<div class="ai-settings">
  <div class="settings-header">
    <div>
      <h3 class="settings-title">AI Configuration</h3>
      <p class="settings-desc">Connect an AI provider to enable natural language log queries and analysis.</p>
    </div>
  </div>

  {#if loading && !config.provider}
    <div class="loading-placeholder">Loading…</div>
  {:else}
    <div class="form">

      <!-- Provider -->
      <div class="field">
        <label for="ai-provider" class="field-label">
          AI Provider
          {#if fromEnv.provider}<span class="env-badge">ENV</span>{/if}
        </label>
        <select
          id="ai-provider"
          bind:value={config.provider}
          disabled={fromEnv.provider}
          class="field-select"
          on:change={clearModel}
        >
          {#each PROVIDERS as p}
            <option value={p.id}>{p.label}</option>
          {/each}
        </select>
      </div>

      <!-- API Key (only if provider requires it) -->
      {#if currentProvider.requiresKey}
        <div class="field">
          <label for="ai-api-key" class="field-label">
            API Key
            {#if fromEnv.api_key}<span class="env-badge">ENV</span>{/if}
          </label>
          <div class="key-row">
            <input
              id="ai-api-key"
              type={showKey ? 'text' : 'password'}
              bind:value={config.api_key}
              disabled={fromEnv.api_key}
              placeholder={currentProvider.placeholder || 'Enter API key…'}
              class="field-input"
            />
            <button type="button" class="toggle-btn" on:click={() => showKey = !showKey}>
              {showKey ? 'Hide' : 'Show'}
            </button>
          </div>
        </div>
      {/if}

      <!-- Base URL (only for Ollama) -->
      {#if currentProvider.requiresUrl}
        <div class="field">
          <label for="ai-base-url" class="field-label">
            Base URL
            {#if fromEnv.base_url}<span class="env-badge">ENV</span>{/if}
          </label>
          <input
            id="ai-base-url"
            type="text"
            bind:value={config.base_url}
            disabled={fromEnv.base_url}
            placeholder="http://localhost:11434"
            class="field-input"
          />
          <p class="field-hint">URL of your Ollama server. Default: http://localhost:11434</p>
        </div>
      {/if}

      <!-- Model -->
      <div class="field">
        <label for="ai-model" class="field-label">
          Model
          {#if fromEnv.model}<span class="env-badge">ENV</span>{/if}
          <span class="optional">(optional)</span>
        </label>
        <div class="model-row">
          <select id="ai-model" bind:value={config.model} disabled={fromEnv.model} class="field-select">
            <option value="">Default ({currentProvider.models[0]})</option>
            {#each currentProvider.models as m}
              <option value={m}>{m}</option>
            {/each}
          </select>
        </div>
        <p class="field-hint">Leave empty to use the provider's recommended model.</p>
      </div>

      <!-- Test result -->
      {#if testResult}
        <div class="test-result" class:success={testResult.status === 'ok'} class:error={testResult.status === 'error'}>
          <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
            {#if testResult.status === 'ok'}
              <path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z"/>
            {:else}
              <path d="M8 1a7 7 0 1 1 0 14A7 7 0 0 1 8 1Zm-.75 4.75v3.5h1.5v-3.5h-1.5Zm0 5v1.5h1.5v-1.5h-1.5Z"/>
            {/if}
          </svg>
          {testResult.message}
          {#if testResult.model}<span class="model-name"> ({testResult.model})</span>{/if}
        </div>
      {/if}

      <div class="actions">
        <button class="btn-test" on:click={testConnection} disabled={testing || loading}>
          {testing ? 'Testing…' : 'Test Connection'}
        </button>
        <button class="btn-save" on:click={save} disabled={loading}>
          {loading ? 'Saving…' : 'Save'}
        </button>
      </div>

      <!-- Feature info -->
      <div class="feature-info">
        <div class="feature-row">
          <span class="feature-badge pro">Pro</span>
          <span class="feature-text">Natural language log queries, query suggestions</span>
        </div>
        <div class="feature-row">
          <span class="feature-badge enterprise">Enterprise</span>
          <span class="feature-text">Batch log analysis, log entry explanation</span>
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  .ai-settings {
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .settings-header { display: flex; align-items: flex-start; justify-content: space-between; }

  .settings-title {
    font-size: 16px;
    font-weight: 600;
    color: var(--text-primary, #c9d1d9);
    margin: 0 0 4px;
  }

  .settings-desc {
    font-size: 13px;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  .loading-placeholder {
    color: var(--text-secondary, #8b949e);
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
    color: var(--text-primary, #c9d1d9);
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .optional { font-weight: 400; color: var(--text-secondary, #8b949e); font-size: 12px; }

  .env-badge {
    font-size: 10px;
    font-weight: 700;
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
    border: 1px solid rgba(210, 153, 34, 0.3);
    border-radius: 4px;
    padding: 1px 5px;
  }

  .field-select, .field-input {
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-primary, #c9d1d9);
    font-size: 13px;
    padding: 7px 10px;
    width: 100%;
    box-sizing: border-box;
    transition: border-color 0.15s;
  }

  .field-select:focus, .field-input:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .field-select:disabled, .field-input:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .field-hint {
    font-size: 12px;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  .key-row, .model-row {
    display: flex;
    gap: 8px;
  }

  .key-row .field-input { flex: 1; }

  .toggle-btn {
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-secondary, #8b949e);
    font-size: 12px;
    padding: 0 12px;
    cursor: pointer;
    white-space: nowrap;
    transition: all 0.15s;
  }

  .toggle-btn:hover {
    background: var(--bg-hover, #30363d);
    color: var(--text-primary, #c9d1d9);
  }

  .test-result {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    padding: 8px 12px;
    border-radius: 6px;
  }

  .test-result.success {
    color: #3fb950;
    background: rgba(63, 185, 80, 0.1);
    border: 1px solid rgba(63, 185, 80, 0.3);
  }

  .test-result.error {
    color: #f85149;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid rgba(248, 81, 73, 0.3);
  }

  .model-name { color: var(--text-secondary, #8b949e); }

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

  .btn-test {
    background: transparent;
    color: var(--text-secondary, #8b949e);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    padding: 7px 16px;
    font-size: 13px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .btn-test:hover:not(:disabled) {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .btn-test:disabled { opacity: 0.5; cursor: not-allowed; }

  .feature-info {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px;
    background: var(--bg-primary, #0d1117);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
  }

  .feature-row {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    color: var(--text-secondary, #8b949e);
  }

  .feature-badge {
    font-size: 10px;
    font-weight: 700;
    padding: 1px 6px;
    border-radius: 4px;
    flex-shrink: 0;
  }

  .feature-badge.pro {
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
    border: 1px solid rgba(88, 166, 255, 0.3);
  }

  .feature-badge.enterprise {
    background: rgba(63, 185, 80, 0.15);
    color: #3fb950;
    border: 1px solid rgba(63, 185, 80, 0.3);
  }
</style>
