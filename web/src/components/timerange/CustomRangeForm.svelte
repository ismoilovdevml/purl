<!--
  CustomRangeForm
  The "Custom Time Range" panel inside TimeRangePicker's dropdown: from/to
  date + time inputs, prefilled with the last hour, and the Cancel/Apply
  actions. It is mounted each time the user opens "Custom range...", so its
  inputs and validation error start fresh every time. Validation happens here;
  the picker only learns about a valid range through `onapply`.
-->
<script>
  import { stopPropagation } from '../../utils/dom.js';

  let {
    /** (from: string, to: string) => void — ISO strings, from < to */
    onapply,
    /** () => void */
    oncancel,
  } = $props();

  // Default to the last hour
  const now = new Date();
  const hourAgo = new Date(now.getTime() - 60 * 60 * 1000);

  let fromDate = $state(hourAgo.toISOString().split('T')[0]);
  let fromTime = $state(hourAgo.toTimeString().slice(0, 5));
  let toDate = $state(now.toISOString().split('T')[0]);
  let toTime = $state(now.toTimeString().slice(0, 5));
  let validationError = $state('');

  function applyCustom() {
    if (!fromDate || !fromTime || !toDate || !toTime) return;

    const from = new Date(`${fromDate}T${fromTime}`);
    const to = new Date(`${toDate}T${toTime}`);

    if (from >= to) {
      validationError = 'Start time must be before end time';
      return;
    }

    validationError = '';
    onapply?.(from.toISOString(), to.toISOString());
  }

  function handleInputChange() {
    validationError = '';
  }
</script>

<div class="custom-range">
  <div class="custom-header">
    <span>Custom Time Range</span>
  </div>

  <div class="datetime-group">
    <label for="from-date">From</label>
    <div class="datetime-inputs">
      <input id="from-date" type="date" bind:value={fromDate} onchange={handleInputChange} />
      <input id="from-time" type="time" bind:value={fromTime} aria-label="From time" onchange={handleInputChange} />
    </div>
  </div>

  <div class="datetime-group">
    <label for="to-date">To</label>
    <div class="datetime-inputs">
      <input id="to-date" type="date" bind:value={toDate} onchange={handleInputChange} />
      <input id="to-time" type="time" bind:value={toTime} aria-label="To time" onchange={handleInputChange} />
    </div>
  </div>

  {#if validationError}
    <div class="validation-error" role="alert">{validationError}</div>
  {/if}

  <div class="custom-actions">
    <button class="btn-cancel" onclick={stopPropagation(() => oncancel?.())}>Cancel</button>
    <button class="btn-apply" onclick={stopPropagation(applyCustom)}>Apply</button>
  </div>
</div>

<style>
  .custom-range {
    padding: 16px;
  }

  .custom-header {
    font-size: 13px;
    font-weight: 600;
    color: #c9d1d9;
    margin-bottom: 16px;
    padding-bottom: 12px;
    border-bottom: 1px solid #30363d;
  }

  .datetime-group {
    margin-bottom: 12px;
  }

  .datetime-group label {
    display: block;
    font-size: 12px;
    color: #8b949e;
    margin-bottom: 6px;
  }

  .datetime-inputs {
    display: flex;
    gap: 8px;
  }

  .datetime-inputs input {
    flex: 1;
    padding: 8px 10px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 13px;
    font-family: inherit;
  }

  .datetime-inputs input:focus {
    border-color: #58a6ff;
  }

  .datetime-inputs input[type="date"] {
    flex: 1.2;
  }

  .datetime-inputs input[type="time"] {
    flex: 0.8;
  }

  .validation-error {
    font-size: 12px;
    color: #f85149;
    margin-top: 8px;
    margin-bottom: 4px;
    padding: 6px 8px;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid rgba(248, 81, 73, 0.3);
    border-radius: 4px;
  }

  .custom-actions {
    display: flex;
    gap: 8px;
    margin-top: 16px;
    padding-top: 12px;
    border-top: 1px solid #30363d;
  }

  .btn-cancel, .btn-apply {
    flex: 1;
    padding: 8px 16px;
    border-radius: 6px;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    border: none;
  }

  .btn-cancel {
    background: #21262d;
    color: #c9d1d9;
  }

  .btn-cancel:hover {
    background: #30363d;
  }

  .btn-apply {
    background: #238636;
    color: #ffffff;
  }

  .btn-apply:hover {
    background: #2ea043;
  }

  /* Dark theme for date/time inputs */
  input[type="date"]::-webkit-calendar-picker-indicator,
  input[type="time"]::-webkit-calendar-picker-indicator {
    filter: invert(0.8);
    cursor: pointer;
  }
</style>
