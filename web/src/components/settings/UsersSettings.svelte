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

  const API_BASE = '/api';

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

  onMount(() => {
    fetchUsers();
    fetchLdapStatus();
  });

  async function fetchLdapStatus() {
    try {
      const res = await fetch(`${API_BASE}/settings/ldap`);
      if (res.ok) {
        const data = await res.json();
        ldapEnabled = !!(data.config?.enabled);
      }
    } catch {
      // ignore — LDAP may not be available (free/pro plan)
    }
  }

  async function fetchUsers() {
    loading = true;
    error = '';
    try {
      const res = await fetch(`${API_BASE}/settings/users`);
      if (res.ok) {
        const data = await res.json();
        users = data.users || [];
      } else {
        const data = await res.json();
        error = data.error || 'Failed to load users';
      }
    } catch {
      error = 'Failed to load users';
    } finally {
      loading = false;
    }
  }

  async function handleAddUser() {
    if (!newUsername.trim() || !newPassword.trim()) return;
    adding = true;
    addError = '';
    try {
      const res = await fetch(`${API_BASE}/settings/users`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          username: newUsername.trim(),
          password: newPassword,
          role: newRole
        })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to create user');
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
      const res = await fetch(`${API_BASE}/settings/users/${changingUser}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to change password');
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
      const res = await fetch(`${API_BASE}/settings/users/${username}`, {
        method: 'DELETE'
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to delete user');
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
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>
        </svg>
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
        <Button variant="primary" size="sm" on:click={() => { showAddForm = !showAddForm; addError = ''; }}>
          {showAddForm ? 'Cancel' : 'Add User'}
        </Button>
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
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/>
                  <circle cx="12" cy="7" r="4"/>
                </svg>
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
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  .loading {
    text-align: center;
    color: var(--text-secondary, #8b949e);
    padding: 20px;
  }

  .error-msg {
    padding: 10px 14px;
    margin-bottom: 16px;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid var(--color-error, #f85149);
    border-radius: 6px;
    color: var(--color-error, #f85149);
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
    color: var(--text-secondary, #8b949e);
  }

  .limit-info {
    color: var(--text-muted, #6e7681);
  }

  .add-form {
    display: flex;
    gap: 12px;
    align-items: flex-end;
    padding: 12px;
    margin-bottom: 16px;
    background: var(--bg-tertiary, #21262d);
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
    color: var(--text-secondary, #8b949e);
  }

  .role-select {
    padding: 6px 10px;
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 6px;
    color: var(--text-primary, #c9d1d9);
    font-size: 0.8125rem;
    cursor: pointer;
    transition: border-color 0.15s;
    min-width: 180px;
  }

  .role-select:focus {
    outline: none;
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
    border-bottom: 1px solid var(--border-color, #30363d);
    margin-bottom: 4px;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-muted, #6e7681);
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
    border-bottom: 1px solid var(--border-color, #21262d);
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

  .user-info svg {
    color: var(--text-muted, #6e7681);
    flex-shrink: 0;
  }

  .username {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary, #c9d1d9);
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
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .form-error {
    width: 100%;
    margin-top: 4px;
    font-size: 0.75rem;
    color: var(--color-error, #f85149);
  }

  .empty {
    text-align: center;
    padding: 20px;
    color: var(--text-muted, #6e7681);
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
    color: var(--text-secondary, #8b949e);
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  .ldap-banner svg {
    flex-shrink: 0;
    margin-top: 2px;
    color: #388bfd;
  }
</style>
