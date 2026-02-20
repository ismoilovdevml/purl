<!--
  LoginPage Component
  Authentication page for Pro/Enterprise plans

  Usage:
  <LoginPage on:login />
-->
<script>
  import { createEventDispatcher } from 'svelte';
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import { login, changePassword, passwordChangeRequired } from '../stores/auth.js';

  const dispatch = createEventDispatcher();

  let username = '';
  let password = '';
  let error = '';
  let loading = false;

  // Password change state
  let currentPassword = '';
  let newPassword = '';
  let confirmPassword = '';

  let ssoAvailable = false;

  // Check if SSO is configured
  async function checkSso() {
    try {
      const res = await fetch('/api/license');
      if (res.ok) {
        const data = await res.json();
        ssoAvailable = (data.features || []).includes('sso');
      }
    } catch { /* ignore */ }
  }

  checkSso();

  async function handleSsoLogin(e) {
    e.preventDefault();
    loading = true;
    error = '';
    try {
      const res = await fetch('/api/auth/sso/login', { redirect: 'manual' });
      if (res.type === 'opaqueredirect' || res.status === 0) {
        window.location.href = '/api/auth/sso/login';
      } else {
        const data = await res.json().catch(() => ({}));
        error = data.error || 'SSO login is not available';
      }
    } catch {
      error = 'SSO login failed. Please try again.';
    } finally {
      loading = false;
    }
  }

  async function handleLogin() {
    if (!username.trim() || !password.trim()) return;
    loading = true;
    error = '';
    try {
      const data = await login(username.trim(), password);
      if (data.password_change_required) {
        // Stay on login page, show password change form
      } else {
        dispatch('login');
      }
    } catch (err) {
      error = err.message;
    } finally {
      loading = false;
    }
  }

  async function handleChangePassword() {
    if (!currentPassword.trim() || !newPassword.trim() || !confirmPassword.trim()) return;
    if (newPassword !== confirmPassword) {
      error = 'Passwords do not match';
      return;
    }
    if (newPassword.length < 8) {
      error = 'Password must be at least 8 characters';
      return;
    }
    if (newPassword === 'admin') {
      error = 'Please choose a different password';
      return;
    }
    loading = true;
    error = '';
    try {
      await changePassword(currentPassword, newPassword);
      dispatch('login');
    } catch (err) {
      error = err.message;
    } finally {
      loading = false;
    }
  }

  function handleKeydown(e) {
    if (e.detail?.key === 'Enter' || e.key === 'Enter') {
      if ($passwordChangeRequired) {
        handleChangePassword();
      } else {
        handleLogin();
      }
    }
  }
</script>

<div class="login-page">
  <div class="login-card">
    <div class="login-logo">
      <svg width="48" height="48" viewBox="0 0 32 32">
        <circle cx="16" cy="16" r="14" fill="none" stroke="#58a6ff" stroke-width="2"/>
        <path d="M10 12 L22 12 M10 16 L22 16 M10 20 L18 20" stroke="#58a6ff" stroke-width="2" stroke-linecap="round"/>
      </svg>
      <h1>Purl</h1>
    </div>

    {#if $passwordChangeRequired}
      <p class="login-subtitle">Change your default password</p>

      <div class="password-warning">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
          <line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
        </svg>
        You are using the default admin password. Please set a new password to continue.
      </div>

      {#if error}
        <div class="login-error">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
          </svg>
          {error}
        </div>
      {/if}

      <div class="login-form">
        <Input
          bind:value={currentPassword}
          label="Current Password"
          placeholder="Enter current password"
          type="password"
          fullWidth
          autocomplete="current-password"
          on:keydown={handleKeydown}
        />

        <Input
          bind:value={newPassword}
          label="New Password"
          placeholder="Enter new password"
          type="password"
          fullWidth
          autocomplete="new-password"
          on:keydown={handleKeydown}
        />

        <Input
          bind:value={confirmPassword}
          label="Confirm Password"
          placeholder="Confirm new password"
          type="password"
          fullWidth
          autocomplete="new-password"
          on:keydown={handleKeydown}
        />

        <Button
          variant="primary"
          fullWidth
          size="lg"
          on:click={handleChangePassword}
          {loading}
          disabled={!currentPassword.trim() || !newPassword.trim() || !confirmPassword.trim()}
        >
          Change Password
        </Button>
      </div>
    {:else}
      <p class="login-subtitle">Sign in to your dashboard</p>

      {#if error}
        <div class="login-error">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
          </svg>
          {error}
        </div>
      {/if}

      <div class="login-form">
        <Input
          bind:value={username}
          label="Username"
          placeholder="Enter username"
          fullWidth
          autocomplete="username"
          on:keydown={handleKeydown}
        />

        <Input
          bind:value={password}
          label="Password"
          placeholder="Enter password"
          type="password"
          fullWidth
          autocomplete="current-password"
          on:keydown={handleKeydown}
        />

        <Button
          variant="primary"
          fullWidth
          size="lg"
          on:click={handleLogin}
          {loading}
          disabled={!username.trim() || !password.trim()}
        >
          Sign In
        </Button>

        {#if ssoAvailable}
          <div class="login-divider">
            <span>or</span>
          </div>
          <a href="/api/auth/sso/login" class="sso-button">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0110 0v4"/>
            </svg>
            Sign in with SSO
          </a>
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .login-page {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 100vh;
    background: #0d1117;
    padding: 20px;
  }

  .login-card {
    width: 100%;
    max-width: 380px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 12px;
    padding: 40px 32px;
  }

  .login-logo {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 12px;
    margin-bottom: 8px;
  }

  .login-logo h1 {
    margin: 0;
    font-size: 1.75rem;
    font-weight: 700;
    color: #58a6ff;
  }

  .login-subtitle {
    text-align: center;
    color: #8b949e;
    font-size: 0.875rem;
    margin: 0 0 28px;
  }

  .login-error {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    margin-bottom: 16px;
    background: rgba(248, 81, 73, 0.1);
    border: 1px solid #f85149;
    border-radius: 6px;
    color: #f85149;
    font-size: 0.8125rem;
  }

  .password-warning {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: 10px 14px;
    margin-bottom: 16px;
    background: rgba(210, 153, 34, 0.1);
    border: 1px solid rgba(210, 153, 34, 0.4);
    border-radius: 6px;
    color: #d29922;
    font-size: 0.8125rem;
    line-height: 1.4;
  }

  .password-warning svg {
    flex-shrink: 0;
    margin-top: 1px;
  }

  .login-form {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .login-divider {
    display: flex;
    align-items: center;
    gap: 10px;
    color: #8b949e;
    font-size: 0.8125rem;
  }

  .login-divider::before,
  .login-divider::after {
    content: '';
    flex: 1;
    height: 1px;
    background: #30363d;
  }

  .sso-button {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    width: 100%;
    padding: 10px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 0.9375rem;
    font-weight: 500;
    text-decoration: none;
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }

  .sso-button:hover {
    background: #30363d;
    color: #f0f6fc;
  }
</style>
