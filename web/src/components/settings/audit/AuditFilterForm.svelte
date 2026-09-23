<!--
  AuditFilterForm
  Body of the audit "Filters" card: actor, action, resource type and a date
  range. AuditSettings owns the values (bound) and runs the search; Enter in
  the actor field submits.
-->
<script>
  let {
    /** Bound: actor (username) filter */
    actor = $bindable(),
    /** Bound: action filter ('' = all) */
    action = $bindable(),
    /** Bound: resource type filter ('' = all) */
    resourceType = $bindable(),
    /** Bound: datetime-local lower bound */
    from = $bindable(),
    /** Bound: datetime-local upper bound */
    to = $bindable(),
    /** Date range validation message ('' = valid) */
    dateError = '',
    /** () => void — Enter in the actor field */
    onsubmit,
  } = $props();

  // Known actions for filter dropdown
  const knownActions = [
    'login', 'logout', 'login_failed',
    'create_user', 'update_user', 'delete_user', 'change_password',
    'create_alert', 'update_alert', 'delete_alert',
    'update_settings',
    'generate_api_key', 'revoke_api_key',
    'create_backup', 'restore_backup', 'delete_backup',
  ];

  const knownResourceTypes = [
    'user', 'alert', 'settings', 'api_key', 'backup', 'session',
  ];
</script>

<div class="filters-form">
  <div class="filter-row">
    <div class="filter-field">
      <label class="filter-label" for="audit-actor">Actor</label>
      <input
        id="audit-actor"
        type="text"
        class="filter-input"
        bind:value={actor}
        placeholder="Username..."
        onkeydown={(e) => e.key === 'Enter' && onsubmit()}
      />
    </div>
    <div class="filter-field">
      <label class="filter-label" for="audit-action">Action</label>
      <select id="audit-action" class="filter-select" bind:value={action}>
        <option value="">All actions</option>
        {#each knownActions as knownAction}
          <option value={knownAction}>{knownAction}</option>
        {/each}
      </select>
    </div>
    <div class="filter-field">
      <label class="filter-label" for="audit-resource">Resource Type</label>
      <select id="audit-resource" class="filter-select" bind:value={resourceType}>
        <option value="">All resources</option>
        {#each knownResourceTypes as rt}
          <option value={rt}>{rt}</option>
        {/each}
      </select>
    </div>
  </div>
  <div class="filter-row">
    <div class="filter-field">
      <label class="filter-label" for="audit-from">From</label>
      <input
        id="audit-from"
        type="datetime-local"
        class="filter-input"
        class:filter-input-error={dateError}
        bind:value={from}
      />
    </div>
    <div class="filter-field">
      <label class="filter-label" for="audit-to">To</label>
      <input
        id="audit-to"
        type="datetime-local"
        class="filter-input"
        class:filter-input-error={dateError}
        bind:value={to}
      />
    </div>
  </div>
  {#if dateError}
    <div class="date-error">{dateError}</div>
  {/if}
</div>

<style>
  /* Filters */
  .filters-form {
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .filter-row {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }

  .filter-field {
    display: flex;
    flex-direction: column;
    gap: 4px;
    flex: 1;
    min-width: 160px;
  }

  .filter-label {
    font-size: 0.7rem;
    font-weight: 500;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .filter-input,
  .filter-select {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-primary);
    padding: 6px 10px;
    font-size: 0.8125rem;
    transition: border-color 0.15s;
  }

  .filter-input:focus,
  .filter-select:focus {
    border-color: var(--color-primary);
    box-shadow: 0 0 0 2px rgba(88, 166, 255, 0.15);
  }

  .filter-select {
    cursor: pointer;
  }

  /* Date validation error */
  .date-error {
    font-size: 0.75rem;
    color: #f85149;
    padding: 2px 0 0;
  }

  .filter-input-error {
    border-color: #f85149 !important;
  }
</style>
