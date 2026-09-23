<!--
  PipelineCreateModal
  "Create Pipeline" modal: name, description, service filter and the rule
  list (add / remove / edit rules). PipelineSettings owns the draft so it
  survives Cancel, and performs the create.
-->
<script>
  import Button from '../../ui/Button.svelte';
  import Modal from '../../ui/Modal.svelte';
  import Icon from '../../ui/Icon.svelte';
  import { close } from '../../ui/icons.js';

  let {
    /** Modal is open */
    open = $bindable(),
    /** Draft: { name, description, filter_service, enabled, rules[] } */
    pipeline = $bindable(),
    /** () => void — submit the draft */
    oncreate,
  } = $props();

  const ruleTypes = [
    { value: 'regex', label: 'Regex Extract' },
    { value: 'json_extract', label: 'JSON Extract' },
    { value: 'grok', label: 'Grok Pattern' },
    { value: 'drop', label: 'Drop' },
    { value: 'mutate', label: 'Mutate' },
  ];

  function addRule() {
    pipeline.rules = [...pipeline.rules, { type: 'regex', source_field: 'message', pattern: '', enabled: true }];
  }

  function removeRule(index) {
    pipeline.rules = pipeline.rules.filter((_, i) => i !== index);
  }
</script>

<Modal bind:open title="Create Pipeline" size="lg">
  <div class="form-group">
    <label for="pipeline-name">Name</label>
    <input id="pipeline-name" type="text" bind:value={pipeline.name} placeholder="My Pipeline" />
  </div>
  <div class="form-group">
    <label for="pipeline-desc">Description</label>
    <input id="pipeline-desc" type="text" bind:value={pipeline.description} placeholder="Parse nginx access logs" />
  </div>
  <div class="form-group">
    <label for="pipeline-filter">Service Filter (regex, empty = all)</label>
    <input id="pipeline-filter" type="text" bind:value={pipeline.filter_service} placeholder="nginx|apache" />
  </div>

  <div class="rules-section">
    <div class="rules-header">
      <h4>Rules</h4>
      <button class="btn-sm" onclick={addRule}>+ Add Rule</button>
    </div>

    {#each pipeline.rules as rule, i}
      <div class="rule-card">
        <div class="rule-row">
          <select bind:value={rule.type}>
            {#each ruleTypes as rt}
              <option value={rt.value}>{rt.label}</option>
            {/each}
          </select>
          <input type="text" bind:value={rule.source_field} placeholder="Source field" />
          <button
            class="btn-sm btn-danger btn-icon"
            onclick={() => removeRule(i)}
            aria-label={`Remove rule ${i + 1} (${rule.type})`}
          >
            <Icon icon={close} size={12} strokeWidth={3} />
          </button>
        </div>
        {#if rule.type === 'regex' || rule.type === 'grok' || rule.type === 'drop'}
          <input type="text" bind:value={rule.pattern} placeholder="Pattern..." class="rule-pattern" />
        {/if}
      </div>
    {/each}
  </div>

  {#snippet footer()}
    <Button onclick={() => open = false}>Cancel</Button>
    <Button variant="primary" onclick={oncreate} disabled={!pipeline.name.trim()}>Create</Button>
  {/snippet}
</Modal>

<style>
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

  /* Icon-only variant of .btn-sm — keeps the square hit area the glyph needs. */
  .btn-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    width: 26px;
    height: 26px;
    flex-shrink: 0;
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

  .form-group input {
    width: 100%;
    padding: 8px 12px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 13px;
  }

  /* Border-color is the resting cue; the global :focus-visible ring is left
     intact so keyboard users keep a visible focus indicator. */
  .form-group input:focus {
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
    font-family: var(--font-mono);
  }
</style>
