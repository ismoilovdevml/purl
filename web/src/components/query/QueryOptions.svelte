<!--
  QueryOptions
  The options row under the query editor: the From/To time range, the row
  limit, the comma-separated field list and the Execute button. QueryPage owns
  every value (they are bound two-way) and runs the query itself.
-->
<script>
  import Button from '../ui/Button.svelte';
  import Icon from '../ui/Icon.svelte';
  import { play } from '../ui/icons.js';

  let {
    /** datetime-local string, '' when unset */
    fromDate = $bindable(),
    /** datetime-local string, '' when unset */
    toDate = $bindable(),
    /** Maximum rows to return */
    limit = $bindable(),
    /** Comma-separated field names, '' for all */
    fields = $bindable(),
    /** A query is in flight */
    loading = false,
    /** () => void */
    onexecute,
  } = $props();
</script>

<div class="options-row">
  <div class="option-group">
    <label for="from-date">From</label>
    <input
      id="from-date"
      type="datetime-local"
      bind:value={fromDate}
      class="option-input datetime-input"
    />
  </div>
  <div class="option-group">
    <label for="to-date">To</label>
    <input
      id="to-date"
      type="datetime-local"
      bind:value={toDate}
      class="option-input datetime-input"
    />
  </div>
  <div class="option-group">
    <label for="limit-input">Limit</label>
    <input
      id="limit-input"
      type="number"
      bind:value={limit}
      class="option-input limit-input"
      min="1"
      max="10000"
    />
  </div>
  <div class="option-group fields-group">
    <label for="fields-input">Fields</label>
    <input
      id="fields-input"
      type="text"
      bind:value={fields}
      class="option-input"
      placeholder="timestamp, level, message"
    />
  </div>
  <div class="option-group execute-group">
    <Button variant="primary" onclick={onexecute} loading={loading}>
      <Icon icon={play} size={16} />
      Execute
    </Button>
  </div>
</div>

<style>
  .options-row {
    display: flex;
    align-items: flex-end;
    gap: 12px;
    margin-bottom: 16px;
    flex-wrap: wrap;
  }

  .option-group {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .option-group label {
    font-size: 0.6875rem;
    font-weight: 500;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .option-input {
    padding: 6px 10px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.8125rem;
    font-family: inherit;
    height: 34px;
    transition: border-color 0.15s;
    box-sizing: border-box;
  }

  .option-input:focus {
    border-color: #58a6ff;
    box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.15);
  }

  .datetime-input {
    width: 220px;
    color-scheme: dark;
  }

  .limit-input {
    width: 90px;
  }

  .fields-group {
    flex: 1;
    min-width: 180px;
  }

  .fields-group .option-input {
    width: 100%;
  }

  .execute-group {
    padding-bottom: 0;
  }

  @media (max-width: 900px) {
    .options-row {
      flex-direction: column;
      align-items: stretch;
    }

    .datetime-input {
      width: 100%;
    }

    .limit-input {
      width: 100%;
    }
  }
</style>
