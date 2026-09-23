<!--
  UserAddForm
  "Add User" form on the Users settings page: username, password, role and
  Create. UsersSettings owns the field values and the request.
-->
<script>
  import Button from '../../ui/Button.svelte';
  import Input from '../../ui/Input.svelte';
  import RoleSelect from './RoleSelect.svelte';

  let {
    /** Username field */
    username = $bindable(),
    /** Password field */
    password = $bindable(),
    /** Role of the new user */
    role = $bindable(),
    /** POST in flight */
    adding = false,
    /** Last create error, or '' */
    error = '',
    /** () => void */
    oncreate,
  } = $props();
</script>

<div class="add-form">
  <Input bind:value={username} placeholder="Username" label="Username" fullWidth />
  <Input bind:value={password} placeholder="Password" label="Password" type="password" fullWidth />
  <RoleSelect id="new-role-select" bind:value={role} />
  <Button variant="success" size="sm" onclick={oncreate} loading={adding} disabled={!username.trim() || !password.trim()}>
    Create
  </Button>
  {#if error}
    <p class="form-error">{error}</p>
  {/if}
</div>

<style>
  .add-form {
    display: flex;
    gap: 12px;
    align-items: flex-end;
    padding: 12px;
    margin-bottom: 16px;
    background: var(--bg-tertiary);
    border-radius: 6px;
    flex-wrap: wrap;
  }

  .form-error {
    width: 100%;
    margin-top: 4px;
    font-size: 0.75rem;
    color: var(--color-error);
  }
</style>
