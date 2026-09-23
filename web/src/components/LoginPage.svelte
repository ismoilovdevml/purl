<!--
  LoginPage Component
  Dashboard sign-in page (local/LDAP credentials, optional SSO)

  Usage:
  <LoginPage onlogin={() => ...} />
-->
<script>
  import Button from './ui/Button.svelte';
  import Input from './ui/Input.svelte';
  import Icon from './ui/Icon.svelte';
  import { logo, alertTriangle, alertCircle, lock } from './ui/icons.js';
  import { login, changePassword, passwordChangeRequired, signInNotice } from '../stores/auth.js';
  import api from '../utils/api.js';

  /**
   * Optional: App reacts to the session store instead, so it passes nothing.
   * @type {{ onlogin?: () => void }}
   */
  let { onlogin } = $props();

  let username = $state('');
  let password = $state('');
  let error = $state('');
  let loading = $state(false);

  // Password change state
  let currentPassword = $state('');
  let newPassword = $state('');
  let confirmPassword = $state('');

  let ssoAvailable = $state(false);

  // Check if SSO is configured (public GET /auth/sso/status).
  // Runs before the user is authenticated, so a 401/404/network failure here is
  // not an error condition — SSO simply stays hidden. Never surface it.
  async function checkSso() {
    try {
      const data = await api.get('/auth/sso/status');
      ssoAvailable = data?.enabled === true;
    } catch { /* ignore */ }
  }

  checkSso();

  async function handleLogin() {
    if (!username.trim() || !password.trim()) return;
    loading = true;
    error = '';
    try {
      const data = await login(username.trim(), password);
      if (data.password_change_required) {
        // Stay on login page, show password change form
      } else {
        onlogin?.();
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
      onlogin?.();
    } catch (err) {
      error = err.message;
    } finally {
      loading = false;
    }
  }

  function handleKeydown(e) {
    if (e?.key === 'Enter') {
      if ($passwordChangeRequired) {
        handleChangePassword();
      } else {
        handleLogin();
      }
    }
  }
</script>

<!--
  A failed sign-in has to be announced, not just drawn — the message replaces no
  focused content, so without role="alert" a screen-reader user gets silence.
  Declared once and rendered from both branches so the two forms can never drift.
-->
{#snippet errorBanner(message)}
  <div class="login-error" role="alert">
    <Icon icon={alertCircle} size={14} />
    {message}
  </div>
{/snippet}

<div class="login-page">
  <div class="login-card">
    <div class="login-logo">
      <Icon icon={logo} size={48} color="#58a6ff" />
      <h1>Purl</h1>
    </div>

    {#if $passwordChangeRequired}
      <p class="login-subtitle">Change your default password</p>

      <div class="login-notice">
        <Icon icon={alertTriangle} size={14} />
        You are using the default admin password. Please set a new password to continue.
      </div>

      {#if error}
        {@render errorBanner(error)}
      {/if}

      <div class="login-form">
        <Input
          bind:value={currentPassword}
          label="Current Password"
          placeholder="Enter current password"
          type="password"
          fullWidth
          autocomplete="current-password"
          onkeydown={handleKeydown}
        />

        <Input
          bind:value={newPassword}
          label="New Password"
          placeholder="Enter new password"
          type="password"
          fullWidth
          autocomplete="new-password"
          onkeydown={handleKeydown}
        />

        <Input
          bind:value={confirmPassword}
          label="Confirm Password"
          placeholder="Confirm new password"
          type="password"
          fullWidth
          autocomplete="new-password"
          onkeydown={handleKeydown}
        />

        <Button
          variant="primary"
          fullWidth
          size="lg"
          onclick={handleChangePassword}
          {loading}
          disabled={!currentPassword.trim() || !newPassword.trim() || !confirmPassword.trim()}
        >
          Change Password
        </Button>
      </div>
    {:else}
      <p class="login-subtitle">Sign in to your dashboard</p>

      {#if $signInNotice}
        <div class="login-notice session-notice" role="status">
          <Icon icon={alertTriangle} size={14} />
          {$signInNotice}
        </div>
      {/if}

      {#if error}
        {@render errorBanner(error)}
      {/if}

      <div class="login-form">
        <Input
          bind:value={username}
          label="Username"
          placeholder="Enter username"
          fullWidth
          autocomplete="username"
          onkeydown={handleKeydown}
        />

        <Input
          bind:value={password}
          label="Password"
          placeholder="Enter password"
          type="password"
          fullWidth
          autocomplete="current-password"
          onkeydown={handleKeydown}
        />

        <Button
          variant="primary"
          fullWidth
          size="lg"
          onclick={handleLogin}
          {loading}
          disabled={!username.trim() || !password.trim()}
        >
          {loading ? 'Signing in...' : 'Sign In'}
        </Button>

        {#if ssoAvailable}
          <div class="login-divider">
            <span>or</span>
          </div>
          <a href="/api/auth/sso/login" class="sso-button">
            <Icon icon={lock} size={16} />
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

  .login-notice {
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

  /* :global — the svg now lives inside <Icon>, outside this component's scope. */
  .login-notice :global(svg) {
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
