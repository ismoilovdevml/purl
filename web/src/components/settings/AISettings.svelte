<script>
  import { onMount } from 'svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { aiProviders } from '../../stores/ai.js';
  import { api } from '../../utils/api.js';
  import EnvBadge from '../ui/EnvBadge.svelte';
  import AIProviderStatus from './ai/AIProviderStatus.svelte';
  import AIFormActions from './ai/AIFormActions.svelte';

  let config = $state({
    provider: 'openai',
    api_key: '',
    model: '',
    base_url: '',
    enabled: true,
  });
  let fromEnv = $state({});
  let loading = $state(false);
  let testing = $state(false);
  let testResult = $state(null);
  let showKey = $state(false);
  let providers = $state([]);
  let activeProvider = $state(null);
  let providersLoading = $state(false);

  const PROVIDERS = [
    {
      id: 'openai', label: 'OpenAI', requiresKey: true, requiresUrl: false, placeholder: 'sk-...',
      models: ['gpt-5.2', 'gpt-5.2-pro', 'gpt-5.1', 'gpt-5-2025-08-07', 'o3-2025-04-16', 'o4-mini-2025-04-16', 'gpt-4.1-2025-04-14', 'gpt-4.1-mini-2025-04-14'],
    },
    {
      id: 'anthropic', label: 'Anthropic', requiresKey: true, requiresUrl: false, placeholder: 'sk-ant-...',
      models: ['claude-haiku-4-5-20251001', 'claude-sonnet-4-6', 'claude-opus-4-6'],
    },
    {
      id: 'gemini', label: 'Google Gemini', requiresKey: true, requiresUrl: false, placeholder: 'AIza...',
      models: ['gemini-3.1-pro-preview', 'gemini-3-pro-preview', 'gemini-3-flash-preview', 'gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.5-flash-lite'],
    },
    {
      id: 'ollama', label: 'Ollama (Self-hosted)', requiresKey: false, requiresUrl: true, placeholder: '',
      models: ['llama3.3', 'qwen2.5', 'deepseek-r1', 'gemma3', 'phi4', 'mistral', 'deepseek-v3'],
    },
  ];

  const currentProvider = $derived(PROVIDERS.find(p => p.id === config.provider) || PROVIDERS[0]);

  onMount(async () => {
    await Promise.all([loadConfig(), loadProviders()]);
  });

  async function loadProviders() {
    providersLoading = true;
    try {
      const data = await api.get('/ai/providers');
      const list = data.providers || [];
      providers = list;
      activeProvider = data.current || null;
      // The raw array, not the $state proxy: the store is shared app-wide.
      aiProviders.set(list);
    } catch {
      // non-fatal — providers status is informational
    } finally {
      providersLoading = false;
    }
  }

  async function loadConfig() {
    loading = true;
    try {
      const data = await api.get('/settings/ai');
      config = { ...config, ...data.config };
      fromEnv = data.from_env || {};
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

      await api.put('/settings/ai', payload);
      toastSuccess('AI settings saved');
      await Promise.all([loadConfig(), loadProviders()]);
    } catch (err) {
      toastError(err.message || 'Failed to save settings');
    } finally {
      loading = false;
    }
  }

  async function testConnection() {
    testing = true;
    testResult = null;
    try {
      testResult = await api.post('/settings/ai/test');
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

  <!-- Provider Status Card -->
  <AIProviderStatus loading={providersLoading} {providers} {activeProvider} />

  {#if loading && !config.provider}
    <div class="loading-placeholder">Loading…</div>
  {:else}
    <div class="form">

      <!-- Enable AI toggle -->
      <div class="field toggle-field">
        <div class="toggle-row">
          <div>
            <div class="field-label">Enable AI</div>
            <p class="field-hint">When disabled, AI features are hidden throughout the dashboard.</p>
          </div>
          <label class="toggle">
            <input type="checkbox" bind:checked={config.enabled} />
            <span class="toggle-track"></span>
          </label>
        </div>
      </div>

      <!-- Provider -->
      <div class="field">
        <label for="ai-provider" class="field-label">
          AI Provider
          <EnvBadge locked={fromEnv.provider} />
        </label>
        <select
          id="ai-provider"
          bind:value={config.provider}
          disabled={fromEnv.provider || !config.enabled}
          class="field-select"
          onchange={clearModel}
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
            <EnvBadge locked={fromEnv.api_key} />
          </label>
          <div class="key-row">
            <input
              id="ai-api-key"
              type={showKey ? 'text' : 'password'}
              bind:value={config.api_key}
              disabled={fromEnv.api_key || !config.enabled}
              placeholder={currentProvider.placeholder || 'Enter API key…'}
              class="field-input"
            />
            <button type="button" class="toggle-btn" onclick={() => showKey = !showKey}>
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
            <EnvBadge locked={fromEnv.base_url} />
          </label>
          <input
            id="ai-base-url"
            type="text"
            bind:value={config.base_url}
            disabled={fromEnv.base_url || !config.enabled}
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
          <EnvBadge locked={fromEnv.model} />
          <span class="optional">(optional)</span>
        </label>
        <div class="model-row">
          <select id="ai-model" bind:value={config.model} disabled={fromEnv.model || !config.enabled} class="field-select">
            <option value="">Default ({currentProvider.models[0]})</option>
            {#each currentProvider.models as m}
              <option value={m}>{m}</option>
            {/each}
          </select>
        </div>
        <p class="field-hint">Leave empty to use the provider's recommended model.</p>
      </div>

      <AIFormActions {testResult} {testing} {loading} ontest={testConnection} onsave={save} />
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

  .field-select, .field-input {
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

  .field-select:focus, .field-input:focus {
    border-color: #58a6ff;
  }

  .field-select:disabled, .field-input:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .field-hint {
    font-size: 12px;
    color: var(--text-secondary);
    margin: 0;
  }

  .key-row, .model-row {
    display: flex;
    gap: 8px;
  }

  .key-row .field-input { flex: 1; }

  .toggle-btn {
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-secondary);
    font-size: 12px;
    padding: 0 12px;
    cursor: pointer;
    white-space: nowrap;
    transition: all 0.15s;
  }

  .toggle-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }


  .toggle-field {
    padding: 12px;
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
  }

  .toggle-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
  }

  .toggle {
    position: relative;
    display: inline-block;
    width: 36px;
    height: 20px;
    flex-shrink: 0;
    cursor: pointer;
  }

  .toggle input { opacity: 0; width: 0; height: 0; }

  .toggle-track {
    position: absolute;
    inset: 0;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 20px;
    transition: background 0.2s, border-color 0.2s;
  }

  .toggle-track::after {
    content: '';
    position: absolute;
    top: 2px;
    left: 2px;
    width: 14px;
    height: 14px;
    background: var(--text-secondary);
    border-radius: 50%;
    transition: transform 0.2s, background 0.2s;
  }

  .toggle input:checked + .toggle-track {
    background: rgba(35, 134, 54, 0.3);
    border-color: #238636;
  }

  .toggle input:checked + .toggle-track::after {
    transform: translateX(16px);
    background: #3fb950;
  }
</style>
