<!--
  UsersTable
  User / Role table on the Users settings page. Each row shows the role badge
  and — for admins — Edit and a two-click inline Delete confirm; the row being
  edited expands into a password/role form beneath it. UsersSettings owns all
  state and requests.
-->
<script>
  import Badge from '../../ui/Badge.svelte';
  import Button from '../../ui/Button.svelte';
  import Input from '../../ui/Input.svelte';
  import Icon from '../../ui/Icon.svelte';
  import { user as userIcon } from '../../ui/icons.js';
  import { currentUser } from '../../../stores/auth.js';
  import RoleSelect from './RoleSelect.svelte';

  let {
    /** Users from GET /settings/users */
    users = [],
    /** Show Edit / Delete */
    isAdmin = false,
    /** LDAP is on: local accounts are marked as fallback */
    ldapEnabled = false,
    /** Username awaiting the Delete confirm, or null */
    deletingUser = null,
    /** Username whose edit form is open, or null */
    changingUser = null,
    /** Edit form: new password */
    changePassword = $bindable(),
    /** Edit form: role */
    changeRole = $bindable(),
    /** PUT in flight */
    changing = false,
    /** Last update error, or '' */
    changeError = '',
    /** (user) => void — open the edit form */
    onedit,
    /** (username | null) => void — arm / disarm the Delete confirm */
    onconfirmdelete,
    /** (username) => void — confirmed delete */
    ondelete,
    /** () => void — save the edit form */
    onsave,
    /** () => void — close the edit form */
    oncanceledit,
  } = $props();

  function roleLabel(role) {
    if (role === 'admin') return 'Admin';
    if (role === 'operator') return 'Operator';
    return 'Viewer';
  }
</script>

<div class="users-table">
  <div class="table-header">
    <span class="col-user">User</span>
    <span class="col-role">Role</span>
    <span class="col-actions"></span>
  </div>

  <div class="users-list">
    {#each users as user}
      <div class="user-row">
        <div class="user-info col-user">
          <Icon icon={userIcon} size={16} strokeWidth={2.25} />
          <span class="username">{user.username}</span>
          {#if $currentUser?.username === user.username}
            <Badge variant="primary" size="sm">You</Badge>
          {/if}
          {#if ldapEnabled}
            <Badge variant="secondary" size="sm">LDAP fallback</Badge>
          {/if}
        </div>
        <div class="col-role">
          <span class="role-badge role-{user.role || 'viewer'}">
            {roleLabel(user.role)}
          </span>
        </div>
        <div class="user-actions col-actions">
          {#if isAdmin}
            <Button variant="ghost" size="sm" onclick={() => onedit(user)}>
              Edit
            </Button>
            {#if $currentUser?.username !== user.username}
              {#if deletingUser === user.username}
                <Button variant="danger" size="sm" onclick={() => ondelete(user.username)}>
                  Confirm
                </Button>
                <Button variant="ghost" size="sm" onclick={() => onconfirmdelete(null)}>
                  Cancel
                </Button>
              {:else}
                <Button variant="ghost" size="sm" onclick={() => onconfirmdelete(user.username)}>
                  Delete
                </Button>
              {/if}
            {/if}
          {/if}
        </div>
      </div>

      {#if changingUser === user.username}
        <div class="change-password-form">
          <Input bind:value={changePassword} placeholder="New password (leave blank to keep)" type="password" fullWidth onenter={onsave} />
          <RoleSelect id="change-role-{user.username}" bind:value={changeRole} />
          <Button variant="primary" size="sm" onclick={onsave} loading={changing} disabled={!changePassword.trim() && changeRole === (user.role || 'viewer')}>
            Save
          </Button>
          <Button variant="ghost" size="sm" onclick={oncanceledit}>
            Cancel
          </Button>
          {#if changeError}
            <p class="form-error">{changeError}</p>
          {/if}
        </div>
      {/if}
    {/each}

    {#if users.length === 0}
      <div class="empty">No users configured.</div>
    {/if}
  </div>
</div>

<style>
  /* Table layout */
  .users-table {
    display: flex;
    flex-direction: column;
  }

  .table-header {
    display: grid;
    grid-template-columns: 1fr 120px auto;
    padding: 6px 0;
    border-bottom: 1px solid var(--border-color);
    margin-bottom: 4px;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .users-list {
    display: flex;
    flex-direction: column;
  }

  .user-row {
    display: grid;
    grid-template-columns: 1fr 120px auto;
    align-items: center;
    padding: 10px 0;
    border-bottom: 1px solid var(--border-muted);
  }

  .user-row:last-child {
    border-bottom: none;
  }

  .col-user {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .col-role {
    display: flex;
    align-items: center;
  }

  .col-actions {
    display: flex;
    gap: 4px;
    justify-content: flex-end;
  }

  .user-info :global(svg) {
    color: var(--text-muted);
    flex-shrink: 0;
  }

  .username {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary);
  }

  /* Role badge */
  .role-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: 9999px;
    font-size: 0.6875rem;
    font-weight: 600;
    letter-spacing: 0.02em;
    text-transform: capitalize;
  }

  .role-admin {
    background: rgba(56, 139, 253, 0.15);
    color: #58a6ff;
  }

  .role-operator {
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
  }

  .role-viewer {
    background: rgba(110, 118, 129, 0.2);
    color: #8b949e;
  }

  .user-actions {
    display: flex;
    gap: 4px;
  }

  .change-password-form {
    display: flex;
    gap: 8px;
    align-items: flex-end;
    padding: 10px 0 10px 24px;
    flex-wrap: wrap;
    border-bottom: 1px solid var(--border-muted);
  }

  .form-error {
    width: 100%;
    margin-top: 4px;
    font-size: 0.75rem;
    color: var(--color-error);
  }

  .empty {
    text-align: center;
    padding: 20px;
    color: var(--text-muted);
    font-size: 0.875rem;
  }
</style>
