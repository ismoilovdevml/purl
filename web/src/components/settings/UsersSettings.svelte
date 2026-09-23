<!--
  UsersSettings Component
  Dashboard user management (local accounts, roles)

  Usage:
  <UsersSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import LoadingSpinner from '../ui/LoadingSpinner.svelte';
  import { currentUser } from '../../stores/auth.js';
  import { success as toastSuccess, error as toastError } from '../../stores/toast.js';
  import { api } from '../../utils/api.js';
  import Icon from '../ui/Icon.svelte';
  import { monitor } from '../ui/icons.js';
  import UserAddForm from './users/UserAddForm.svelte';
  import UsersTable from './users/UsersTable.svelte';

  let users = $state([]);
  let loading = $state(true);
  let error = $state('');
  let ldapEnabled = $state(false);

  // Add user form
  let showAddForm = $state(false);
  let newUsername = $state('');
  let newPassword = $state('');
  let newRole = $state('viewer');
  let addError = $state('');
  let adding = $state(false);

  // Change password / role form
  let changingUser = $state(null);
  let changePassword = $state('');
  let changeRole = $state('');
  let changeError = $state('');
  let changing = $state(false);

  // Delete confirmation
  let deletingUser = $state(null);

  const isAdmin = $derived($currentUser?.role === 'admin');

  onMount(() => {
    fetchUsers();
    fetchLdapStatus();
  });

  async function fetchLdapStatus() {
    try {
      const data = await api.get('/settings/ldap');
      ldapEnabled = !!(data.config?.enabled);
    } catch {
      // ignore — LDAP status is informational only; the user list still works
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
        </span>
        {#if isAdmin}
          <Button variant="primary" size="sm" onclick={() => { showAddForm = !showAddForm; addError = ''; }}>
            {showAddForm ? 'Cancel' : 'Add User'}
          </Button>
        {/if}
      </div>

      {#if showAddForm}
        <UserAddForm
          bind:username={newUsername}
          bind:password={newPassword}
          bind:role={newRole}
          {adding}
          error={addError}
          oncreate={handleAddUser}
        />
      {/if}

      <UsersTable
        {users}
        {isAdmin}
        {ldapEnabled}
        {deletingUser}
        {changingUser}
        bind:changePassword
        bind:changeRole
        {changing}
        {changeError}
        onedit={startChanging}
        onconfirmdelete={(username) => { deletingUser = username; }}
        ondelete={handleDeleteUser}
        onsave={handleChangePassword}
        oncanceledit={() => { changingUser = null; }}
      />
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
