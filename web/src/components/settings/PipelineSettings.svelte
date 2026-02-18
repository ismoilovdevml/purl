<script>
  import { onMount } from 'svelte';
  import Button from '../ui/Button.svelte';
  import Card from '../ui/Card.svelte';
  import Modal from '../ui/Modal.svelte';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';

  let pipelines = [];
  let loading = false;
  let showCreateModal = false;
  let showTestModal = false;

  // New pipeline form
  let newPipeline = {
    name: '',
    description: '',
    filter_service: '',
    enabled: true,
    rules: [],
  };

  // Test state
  let testSample = '{"level":"ERROR","message":"Connection timeout to db-01","service":"api"}';
  let testResults = null;
  let testPipeline = null;

  const ruleTypes = [
    { value: 'regex', label: 'Regex Extract' },
    { value: 'json_extract', label: 'JSON Extract' },
    { value: 'grok', label: 'Grok Pattern' },
    { value: 'drop', label: 'Drop' },
    { value: 'mutate', label: 'Mutate' },
  ];

  onMount(fetchPipelines);

  async function fetchPipelines() {
    loading = true;
    try {
      const res = await fetch('/api/pipelines');
      if (!res.ok) throw new Error('Failed to fetch');
      const data = await res.json();
      pipelines = data.pipelines || [];
    } catch (err) {
      toastError(err.message);
    } finally {
      loading = false;
    }
  }

  async function handleCreate() {
    try {
      const res = await fetch('/api/pipelines', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(newPipeline),
      });
      if (!res.ok) {
        const data = await res.json();
        throw new Error(data.error || 'Failed to create');
      }
      toastSuccess('Pipeline created');
      showCreateModal = false;
      newPipeline = { name: '', description: '', filter_service: '', enabled: true, rules: [] };
      await fetchPipelines();
    } catch (err) {
      toastError(err.message);
    }
  }

  async function toggleEnabled(pipeline) {
    try {
      const res = await fetch(`/api/pipelines/${pipeline.id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ enabled: !pipeline.enabled }),
      });
      if (!res.ok) throw new Error('Failed to update');
      await fetchPipelines();
    } catch (err) {
      toastError(err.message);
    }
  }

  async function deletePipeline(id) {
    if (!confirm('Delete this pipeline?')) return;
    try {
      const res = await fetch(`/api/pipelines/${id}`, { method: 'DELETE' });
      if (!res.ok) throw new Error('Failed to delete');
      toastSuccess('Pipeline deleted');
      await fetchPipelines();
    } catch (err) {
      toastError(err.message);
    }
  }

  function addRule() {
    newPipeline.rules = [...newPipeline.rules, { type: 'regex', source_field: 'message', pattern: '', enabled: true }];
  }

  function removeRule(index) {
    newPipeline.rules = newPipeline.rules.filter((_, i) => i !== index);
  }

  async function openTest(pipeline) {
    testPipeline = pipeline;
    testResults = null;
    showTestModal = true;
  }

  async function runTest() {
    try {
      const samples = [JSON.parse(testSample)];
      const res = await fetch('/api/pipelines/test', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pipeline: testPipeline, samples }),
      });
      if (!res.ok) throw new Error('Test failed');
      const data = await res.json();
      testResults = data.results;
    } catch (err) {
      toastError(err.message);
    }
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Log Pipelines</h3>
    <p>Configure rules to parse and enrich logs during ingestion</p>
  </div>

  <div class="pipeline-actions">
    <Button on:click={() => showCreateModal = true}>Create Pipeline</Button>
  </div>

  {#if loading}
    <p class="loading-text">Loading pipelines...</p>
  {:else if pipelines.length === 0}
    <Card>
      <div class="empty-state">
        <p>No pipelines configured. Create one to start processing logs.</p>
      </div>
    </Card>
  {:else}
    {#each pipelines as pipeline}
      <Card>
        <div class="pipeline-item">
          <div class="pipeline-info">
            <div class="pipeline-name">
              <span class="status-dot" class:enabled={pipeline.enabled}></span>
              {pipeline.name}
            </div>
            {#if pipeline.description}
              <div class="pipeline-desc">{pipeline.description}</div>
            {/if}
            <div class="pipeline-meta">
              {(pipeline.rules || []).length} rules
              {#if pipeline.filter_service}
                &middot; Service: <code>{pipeline.filter_service}</code>
              {/if}
            </div>
          </div>
          <div class="pipeline-actions-row">
            <button class="btn-sm" on:click={() => toggleEnabled(pipeline)}>
              {pipeline.enabled ? 'Disable' : 'Enable'}
            </button>
            <button class="btn-sm" on:click={() => openTest(pipeline)}>Test</button>
            <button class="btn-sm btn-danger" on:click={() => deletePipeline(pipeline.id)}>Delete</button>
          </div>
        </div>
      </Card>
    {/each}
  {/if}
</section>

{#if showCreateModal}
  <Modal bind:open={showCreateModal} title="Create Pipeline" size="lg">
    <div class="form-group">
      <label for="pipeline-name">Name</label>
      <input id="pipeline-name" type="text" bind:value={newPipeline.name} placeholder="My Pipeline" />
    </div>
    <div class="form-group">
      <label for="pipeline-desc">Description</label>
      <input id="pipeline-desc" type="text" bind:value={newPipeline.description} placeholder="Parse nginx access logs" />
    </div>
    <div class="form-group">
      <label for="pipeline-filter">Service Filter (regex, empty = all)</label>
      <input id="pipeline-filter" type="text" bind:value={newPipeline.filter_service} placeholder="nginx|apache" />
    </div>

    <div class="rules-section">
      <div class="rules-header">
        <h4>Rules</h4>
        <button class="btn-sm" on:click={addRule}>+ Add Rule</button>
      </div>

      {#each newPipeline.rules as rule, i}
        <div class="rule-card">
          <div class="rule-row">
            <select bind:value={rule.type}>
              {#each ruleTypes as rt}
                <option value={rt.value}>{rt.label}</option>
              {/each}
            </select>
            <input type="text" bind:value={rule.source_field} placeholder="Source field" />
            <button class="btn-sm btn-danger" on:click={() => removeRule(i)}>&times;</button>
          </div>
          {#if rule.type === 'regex' || rule.type === 'grok' || rule.type === 'drop'}
            <input type="text" bind:value={rule.pattern} placeholder="Pattern..." class="rule-pattern" />
          {/if}
        </div>
      {/each}
    </div>

    <svelte:fragment slot="footer">
      <Button on:click={() => showCreateModal = false}>Cancel</Button>
      <Button variant="primary" on:click={handleCreate} disabled={!newPipeline.name.trim()}>Create</Button>
    </svelte:fragment>
  </Modal>
{/if}

{#if showTestModal}
  <Modal bind:open={showTestModal} title="Test Pipeline" size="lg">
    <div class="form-group">
      <label for="test-sample">Sample Log (JSON)</label>
      <textarea id="test-sample" bind:value={testSample} rows="4" class="code-input"></textarea>
    </div>
    <Button on:click={runTest}>Run Test</Button>

    {#if testResults}
      <div class="test-results">
        {#each testResults as result}
          <div class="test-result">
            <h5>{result.dropped ? 'DROPPED' : 'Output'}</h5>
            <pre>{JSON.stringify(result.dropped ? result.input : result.output, null, 2)}</pre>
          </div>
        {/each}
      </div>
    {/if}

    <svelte:fragment slot="footer">
      <Button on:click={() => showTestModal = false}>Close</Button>
    </svelte:fragment>
  </Modal>
{/if}

<style>
  .settings-section {
    max-width: 800px;
  }

  .section-header {
    margin-bottom: 16px;
  }

  .section-header h3 {
    font-size: 16px;
    font-weight: 600;
    color: #f0f6fc;
    margin-bottom: 4px;
  }

  .section-header p {
    font-size: 13px;
    color: #8b949e;
  }

  .pipeline-actions {
    margin-bottom: 16px;
  }

  .pipeline-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
  }

  .pipeline-name {
    display: flex;
    align-items: center;
    gap: 8px;
    font-weight: 600;
    color: #f0f6fc;
    font-size: 14px;
  }

  .status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #8b949e;
  }

  .status-dot.enabled {
    background: #238636;
  }

  .pipeline-desc {
    font-size: 12px;
    color: #8b949e;
    margin-top: 4px;
  }

  .pipeline-meta {
    font-size: 12px;
    color: #8b949e;
    margin-top: 4px;
  }

  .pipeline-meta code {
    background: #21262d;
    padding: 1px 4px;
    border-radius: 3px;
    font-size: 11px;
  }

  .pipeline-actions-row {
    display: flex;
    gap: 6px;
  }

  .btn-sm {
    padding: 4px 10px;
    font-size: 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
  }

  .btn-sm:hover {
    background: #30363d;
  }

  .btn-danger {
    color: #f85149;
    border-color: rgba(248, 81, 73, 0.3);
  }

  .btn-danger:hover {
    background: rgba(248, 81, 73, 0.1);
  }

  .loading-text, .empty-state {
    text-align: center;
    color: #8b949e;
    padding: 20px;
    font-size: 13px;
  }

  .form-group {
    margin-bottom: 14px;
  }

  .form-group label {
    display: block;
    font-size: 13px;
    color: #c9d1d9;
    margin-bottom: 4px;
  }

  .form-group input, .form-group textarea {
    width: 100%;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 13px;
  }

  .form-group input:focus, .form-group textarea:focus {
    outline: none;
    border-color: #58a6ff;
  }

  .rules-section {
    margin-top: 16px;
  }

  .rules-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
  }

  .rules-header h4 {
    font-size: 14px;
    color: #f0f6fc;
  }

  .rule-card {
    background: #0d1117;
    border: 1px solid #21262d;
    border-radius: 6px;
    padding: 10px;
    margin-bottom: 8px;
  }

  .rule-row {
    display: flex;
    gap: 8px;
    align-items: center;
  }

  .rule-row select {
    padding: 6px 8px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #c9d1d9;
    font-size: 12px;
  }

  .rule-row input {
    flex: 1;
    padding: 6px 8px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #c9d1d9;
    font-size: 12px;
  }

  .rule-pattern {
    width: 100%;
    padding: 6px 8px;
    margin-top: 8px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #c9d1d9;
    font-size: 12px;
    font-family: 'SFMono-Regular', Consolas, monospace;
  }

  .code-input {
    font-family: 'SFMono-Regular', Consolas, monospace;
    resize: vertical;
  }

  .test-results {
    margin-top: 16px;
  }

  .test-result {
    background: #0d1117;
    border: 1px solid #21262d;
    border-radius: 6px;
    padding: 10px;
    margin-bottom: 8px;
  }

  .test-result h5 {
    font-size: 12px;
    color: #8b949e;
    margin-bottom: 6px;
  }

  .test-result pre {
    font-size: 12px;
    color: #c9d1d9;
    font-family: 'SFMono-Regular', Consolas, monospace;
    white-space: pre-wrap;
    word-break: break-all;
  }
</style>
