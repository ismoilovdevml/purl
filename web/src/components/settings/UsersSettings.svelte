<!--
  UsersSettings Component
  User management for Pro/Enterprise plans

  Usage:
  <UsersSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';
  import Button from '../ui/Button.svelte';
  import Input from '../ui/Input.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import { licenseLimits } from '../../stores/license.js';
  import { currentUser } from '../../stores/auth.js';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import Icon from '../ui/Icon.svelte';
  import { monitor, user as userIcon } from '../ui/icons.js';

  let users = [];
  let loading = true;
  let error = '';
  let ldapEnabled = false;

  // Add user form
  let showAddForm = false;
  let newUsername = '';
  let newPassword = '';
  let newRole = 'viewer';
  let addError = '';
  let adding = false;

  // Change password / role form
  let changingUser = null;
  let changePassword = '';
  let changeRole = '';
  let changeError = '';
  let changing = false;

  // Delete confirmation
  let deletingUser = null;

  $: isAdmin = $currentUser?.role === 'admin';

  onMount(() => {
    fetchUsers();
    fetchLdapStatus();
  });

  async function fetchLdapStatus() {
    try {
      const data = await api.get('/settings/ldap');
      ldapEnabled = !!(data.config?.enabled);
    } catch {
      // ignore — LDAP may not be available (free/pro plan)
    }
  }

  async function fetchUsers() {
    loading = true;
    error = '';
    try {
      const data = await api.get('/settings/users');
      users = data.users || [];
    } catch (err) {
      error = err.message || 'Failed to load users';
    } finally {
      loading = false;
    }
  }

  async function handleAddUser() {
    if (!newUsername.trim() || !newPassword.trim()) return;
    adding = true;
    addError = '';
    try {
      await api.post('/settings/users', {
        username: newUsername.trim(),
        password: newPassword,
        role: newRole
      });
      toastSuccess(`User "${newUsername.trim()}" created successfully`);
      newUsername = '';
      newPassword = '';
      newRole = 'viewer';
      showAddForm = false;
      await fetchUsers();
    } catch (err) {
      addError = err.message;
      toastError('Failed to create user: ' + err.message);
    } finally {
      adding = false;
    }
  }

  async function handleChangePassword() {
    if (!changePassword.trim()) return;
    changing = true;
    changeError = '';
    try {
      const body = { password: changePassword };
      if (changeRole) body.role = changeRole;
      await api.put(`/settings/users/${changingUser}`, body);
      toastSuccess('User updated successfully');
      changingUser = null;
      changePassword = '';
      changeRole = '';
      await fetchUsers();
    } catch (err) {
      changeError = err.message;
      toastError('Failed to update user: ' + err.message);
    } finally {
      changing = false;
    }
  }

  async function handleDeleteUser(username) {
    try {
      await api.del(`/settings/users/${username}`);
      toastSuccess(`User "${username}" deleted`);
      deletingUser = null;
      await fetchUsers();
    } catch (err) {
      error = err.message;
      toastError('Failed to delete user: ' + err.message);
    }
  }

  function startChanging(user) {
    changingUser = user.username;
    changePassword = '';
    changeRole = user.role || 'viewer';
    changeError = '';
  }

  function roleLabel(role) {
    if (role === 'admin') return 'Admin';
    if (role === 'operator') return 'Operator';
    return 'Viewer';
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Users</h3>
    <p>Manage dashboard access</p>
  </div>

  {#if loading}
    <Card padding="lg">
      <LoadingSpinner centered label="Loading users..." />
    </Card>
  {:else}
    {#if error}
      <div class="error-msg">{error}</div>
    {/if}

    {#if ldapEnabled}
      <div class="ldap-banner">
        <Icon icon={monitor} size={14} strokeWidth={2.5} />
        <span>LDAP/AD authentication is active. Users can log in with their directory credentials. Local accounts serve as fallback when LDAP is unavailable.</span>
      </div>
    {/if}

    <Card padding="md">
      <div class="users-header">
        <span class="user-count">
          {users.length} user{users.length !== 1 ? 's' : ''}
          {#if $licenseLimits?.users}
            <span class="limit-info">/ {$licenseLimits.users === -1 || $licenseLimits.users === 999 ? '∞' : $licenseLimits.users} max</span>
          {/if}
        </span>
        {#if isAdmin}
          <Button variant="primary" size="sm" on:click={() => { showAddForm = !showAddForm; addError = ''; }}>
            {showAddForm ? 'Cancel' : 'Add User'}
          </Button>
        {/if}
      </div>

      {#if showAddForm}
        <div class="add-form">
          <Input bind:value={newUsername} placeholder="Username" label="Username" fullWidth />
          <Input bind:value={newPassword} placeholder="Password" label="Password" type="password" fullWidth />
          <div class="form-field">
            <label class="form-label" for="new-role-select">Role</label>
            <select id="new-role-select" class="role-select" bind:value={newRole}>
              <option value="viewer">Viewer (read-only)</option>
              <option value="operator">Operator (manage alerts)</option>
              <option value="admin">Admin (full access)</option>
            </select>
          </div>
          <Button variant="success" size="sm" on:click={handleAddUser} loading={adding} disabled={!newUsername.trim() || !newPassword.trim()}>
            Create
          </Button>
          {#if addError}
            <p class="form-error">{addError}</p>
          {/if}
        </div>
      {/if}

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
                  <Button variant="ghost" size="sm" on:click={() => startChanging(user)}>
                    Edit
                  </Button>
                  {#if $currentUser?.username !== user.username}
                    {#if deletingUser === user.username}
                      <Button variant="danger" size="sm" on:click={() => handleDeleteUser(user.username)}>
                        Confirm
                      </Button>
                      <Button variant="ghost" size="sm" on:click={() => deletingUser = null}>
                        Cancel
                      </Button>
                    {:else}
                      <Button variant="ghost" size="sm" on:click={() => deletingUser = user.username}>
                        Delete
                      </Button>
                    {/if}
                  {/if}
                {/if}
              </div>
            </div>

            {#if changingUser === user.username}
              <div class="change-password-form">
                <Input bind:value={changePassword} placeholder="New password (leave blank to keep)" type="password" fullWidth on:enter={handleChangePassword} />
                <div class="form-field">
                  <label class="form-label" for="change-role-{user.username}">Role</label>
                  <select id="change-role-{user.username}" class="role-select" bind:value={changeRole}>
                    <option value="viewer">Viewer (read-only)</option>
                    <option value="operator">Operator (manage alerts)</option>
                    <option value="admin">Admin (full access)</option>
                  </select>
                </div>
                <Button variant="primary" size="sm" on:click={handleChangePassword} loading={changing} disabled={!changePassword.trim() && changeRole === (user.role || 'viewer')}>
                  Save
                </Button>
                <Button variant="ghost" size="sm" on:click={() => changingUser = null}>
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
    </Card>
  {/if}
</section>

<style>
  .settings-section {
    max-width: 700px;
  }

  .section-header {
    margin-bottom: 24px;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-bright);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary);
    margin: 0;
  }

  .loading {
    text-align: center;
    color: var(--text-secondary);
    padding: 20px;
  }

  .error-msg {
    padding: 10px 14px;
    margin-bottom: 16px;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid var(--color-error);
    border-radius: 6px;
    color: var(--color-error);
    font-size: 0.8125rem;
  }

  .users-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
  }

  .user-count {
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  .limit-info {
    color: var(--text-muted);
  }

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

  .ldap-banner {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: 10px 14px;
    margin-bottom: 16px;
    background: rgba(31, 111, 235, 0.1);
    border: 1px solid rgba(31, 111, 235, 0.3);
    border-radius: 6px;
    color: var(--text-secondary);
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  .ldap-banner :global(svg) {
    flex-shrink: 0;
    margin-top: 2px;
    color: #388bfd;
  }
</style>
