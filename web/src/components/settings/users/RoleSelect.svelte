<!--
  RoleSelect
  Labelled Viewer / Operator / Admin <select>, shared by the Add User form
  and the inline edit form on the Users settings page.
-->
<script>
  let {
    /** id of the <select>, also the label's for= */
    id,
    /** Selected role: 'viewer' | 'operator' | 'admin' */
    value = $bindable(),
  } = $props();
</script>

<div class="form-field">
  <label class="form-label" for={id}>Role</label>
  <select {id} class="role-select" bind:value>
    <option value="viewer">Viewer (read-only)</option>
    <option value="operator">Operator (manage alerts)</option>
    <option value="admin">Admin (full access)</option>
  </select>
</div>

<style>
  .form-field {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .form-label {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .role-select {
    padding: 6px 10px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-primary);
    font-size: 0.8125rem;
    cursor: pointer;
    transition: border-color 0.15s;
    min-width: 180px;
  }

  /* Border-color is the resting cue; the global :focus-visible ring stays. */
  .role-select:focus {
    border-color: #388bfd;
  }
</style>
