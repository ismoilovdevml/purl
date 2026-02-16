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
  import { licenseLimits } from '../../stores/license.js';
  import { currentUser } from '../../stores/auth.js';

  const API_BASE = '/api';

  let users = [];
  let loading = true;
  let error = '';

  // Add user form
  let showAddForm = false;
  let newUsername = '';
  let newPassword = '';
  let addError = '';
  let adding = false;

  // Change password form
  let changingUser = null;
  let changePassword = '';
  let changeError = '';
  let changing = false;

  // Delete confirmation
  let deletingUser = null;

  onMount(() => {
    fetchUsers();
  });

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
        body: JSON.stringify({ username: newUsername.trim(), password: newPassword })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to create user');
      newUsername = '';
      newPassword = '';
      showAddForm = false;
      await fetchUsers();
    } catch (err) {
      addError = err.message;
    } finally {
      adding = false;
    }
  }

  async function handleChangePassword() {
    if (!changePassword.trim()) return;
    changing = true;
    changeError = '';
    try {
      const res = await fetch(`${API_BASE}/settings/users/${changingUser}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password: changePassword })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Failed to change password');
      changingUser = null;
      changePassword = '';
    } catch (err) {
      changeError = err.message;
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
      deletingUser = null;
      await fetchUsers();
    } catch (err) {
      error = err.message;
    }
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>Users</h3>
    <p>Manage dashboard access</p>
  </div>

  {#if loading}
    <Card padding="lg">
      <div class="loading">Loading users...</div>
    </Card>
  {:else}
    {#if error}
      <div class="error-msg">{error}</div>
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
          <Button variant="success" size="sm" on:click={handleAddUser} loading={adding} disabled={!newUsername.trim() || !newPassword.trim()}>
            Create
          </Button>
          {#if addError}
            <p class="form-error">{addError}</p>
          {/if}
        </div>
      {/if}

      <div class="users-list">
        {#each users as user}
          <div class="user-row">
            <div class="user-info">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/>
                <circle cx="12" cy="7" r="4"/>
              </svg>
              <span class="username">{user.username}</span>
              {#if $currentUser?.username === user.username}
                <Badge variant="primary" size="sm">You</Badge>
              {/if}
            </div>
            <div class="user-actions">
              <Button variant="ghost" size="sm" on:click={() => { changingUser = user.username; changePassword = ''; changeError = ''; }}>
                Change Password
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
              <Input bind:value={changePassword} placeholder="New password" type="password" fullWidth on:enter={handleChangePassword} />
              <Button variant="primary" size="sm" on:click={handleChangePassword} loading={changing} disabled={!changePassword.trim()}>
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

  .users-list {
    display: flex;
    flex-direction: column;
  }

  .user-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px 0;
    border-bottom: 1px solid var(--border-color, #21262d);
  }

  .user-row:last-child {
    border-bottom: none;
  }

  .user-info {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .user-info svg {
    color: var(--text-muted, #6e7681);
  }

  .username {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary, #c9d1d9);
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
</style>
