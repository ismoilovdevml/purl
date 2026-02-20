<script>
  import Modal from '../ui/Modal.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import { aiAnalysisResult, aiAnalysisLoading, analyzeSelectedLogs } from '../../stores/ai.js';

  export let open = false;
  export let selectedLogs = [];

  $: result = $aiAnalysisResult;
  $: loading = $aiAnalysisLoading;

  const SEVERITY_COLOR = {
    low:      '#3fb950',
    medium:   '#d29922',
    high:     '#f0883e',
    critical: '#f85149',
  };

  async function runAnalysis() {
    if (!selectedLogs.length) return;
    await analyzeSelectedLogs(selectedLogs);
  }

  $: if (open && selectedLogs.length > 0 && !result && !loading) {
    runAnalysis();
  }

  function handleClose() {
    open = false;
    aiAnalysisResult.set(null);
  }
</script>

<Modal bind:open title="AI Log Analysis" size="lg" on:close={handleClose}>
  <div class="analysis-panel">
    {#if loading}
      <div class="loading-state">
        <LoadingSpinner />
        <p>AI is analyzing {selectedLogs.length} log{selectedLogs.length !== 1 ? 's' : ''}…</p>
      </div>

    {:else if result}
      <div class="result-body">
        <!-- Severity badge -->
        <div class="severity-row">
          <span class="severity-badge" style="color: {SEVERITY_COLOR[result.severity] || '#8b949e'}; border-color: {SEVERITY_COLOR[result.severity] || '#8b949e'}40; background: {SEVERITY_COLOR[result.severity] || '#8b949e'}15">
            {(result.severity || 'unknown').toUpperCase()}
          </span>
          {#if result.analyzed_count}
            <span class="analyzed-count">{result.analyzed_count} logs analyzed</span>
          {/if}
        </div>

        <!-- Summary -->
        <div class="result-section">
          <h4 class="section-title">Summary</h4>
          <p class="summary-text">{result.summary}</p>
        </div>

        <!-- Root Causes -->
        {#if result.root_causes && result.root_causes.length > 0}
          <div class="result-section">
            <h4 class="section-title">Root Causes</h4>
            <ul class="item-list">
              {#each result.root_causes as cause}
                <li class="item item-error">
                  <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
                    <path d="M8 1a7 7 0 1 1 0 14A7 7 0 0 1 8 1Zm-.75 4.75v3.5h1.5v-3.5h-1.5Zm0 5v1.5h1.5v-1.5h-1.5Z"/>
                  </svg>
                  {cause}
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        <!-- Services affected -->
        {#if result.services && result.services.length > 0}
          <div class="result-section">
            <h4 class="section-title">Affected Services</h4>
            <div class="tags-row">
              {#each result.services as svc}
                <span class="service-tag">{svc}</span>
              {/each}
            </div>
          </div>
        {/if}

        <!-- Suggestions -->
        {#if result.suggestions && result.suggestions.length > 0}
          <div class="result-section">
            <h4 class="section-title">Suggested Actions</h4>
            <ul class="item-list">
              {#each result.suggestions as s}
                <li class="item item-suggestion">
                  <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
                    <path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z"/>
                  </svg>
                  {s}
                </li>
              {/each}
            </ul>
          </div>
        {/if}
      </div>

    {:else}
      <div class="loading-state">
        <p>Select logs and click Analyze to start.</p>
      </div>
    {/if}
  </div>

  <svelte:fragment slot="footer">
    {#if result}
      <button class="btn-secondary" on:click={runAnalysis} disabled={loading}>Re-analyze</button>
    {/if}
    <button class="btn-primary" on:click={handleClose}>Close</button>
  </svelte:fragment>
</Modal>

<style>
  .analysis-panel {
    min-height: 200px;
  }

  .loading-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    padding: 40px 0;
    color: var(--text-secondary, #8b949e);
    font-size: 14px;
  }

  .result-body {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .severity-row {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .severity-badge {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.5px;
    padding: 3px 10px;
    border-radius: 12px;
    border: 1px solid;
  }

  .analyzed-count {
    font-size: 12px;
    color: var(--text-secondary, #8b949e);
  }

  .result-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .section-title {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin: 0;
  }

  .summary-text {
    font-size: 14px;
    color: var(--text-primary, #c9d1d9);
    line-height: 1.6;
    margin: 0;
  }

  .item-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .item {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    font-size: 13px;
    padding: 6px 10px;
    border-radius: 6px;
    line-height: 1.5;
  }

  .item svg { flex-shrink: 0; margin-top: 2px; }

  .item-error {
    color: #f0883e;
    background: rgba(240, 136, 62, 0.08);
  }

  .item-suggestion {
    color: #3fb950;
    background: rgba(63, 185, 80, 0.08);
  }

  .tags-row {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .service-tag {
    font-size: 12px;
    background: rgba(88, 166, 255, 0.1);
    color: #58a6ff;
    border: 1px solid rgba(88, 166, 255, 0.3);
    border-radius: 4px;
    padding: 2px 8px;
  }

  .btn-primary {
    background: #238636;
    color: #fff;
    border: none;
    border-radius: 6px;
    padding: 6px 16px;
    font-size: 13px;
    cursor: pointer;
    transition: background 0.15s;
  }

  .btn-primary:hover { background: #2ea043; }

  .btn-secondary {
    background: transparent;
    color: var(--text-secondary, #8b949e);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    padding: 6px 16px;
    font-size: 13px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .btn-secondary:hover {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .btn-secondary:disabled { opacity: 0.5; cursor: not-allowed; }
</style>
