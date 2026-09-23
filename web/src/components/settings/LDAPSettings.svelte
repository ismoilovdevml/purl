<!--
  LDAPSettings Component
  LDAP / Active Directory authentication configuration

  Usage:
  <LDAPSettings />
-->
<script>
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import Input from '../ui/Input.svelte';
  import Select from '../ui/Select.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import EnvBadge from '../ui/EnvBadge.svelte';
  import { api } from '../../utils/api.js';
  import { isEnvLocked } from '../../utils/envLock.js';
  import Icon from '../ui/Icon.svelte';
  import { caretDown, check, close } from '../ui/icons.js';

  // ── Page state ─────────────────────────────────────────────────────────────
  let loading = $state(true);
  let saveMsg = $state('');
  let saveError = $state('');
  let saving = $state(false);

  // ── Test connection state ──────────────────────────────────────────────────
  let testing = $state(false);
  let testResult = $state(null); // null | { ok: boolean, message: string }

  // ── Advanced section toggle ────────────────────────────────────────────────
  let showAdvanced = $state(false);

  /*
   * Which ldap.* keys the environment owns: { server: 1, bind_dn: 0, ... }.
   * GET /settings/ldap has always sent this map (as `from_env`); this page
   * ignored it, so a field pinned by PURL_LDAP_* rendered editable and the save
   * came back 409.
   */
  let fromEnv = $state({});

  // ── Form fields ────────────────────────────────────────────────────────────
  let enabled = $state(false);

  // Server
  let serverUrl = $state('ldap://dc.example.com');
  let port = $state('389');
  let useTLS = $state(false);
  let tlsVerify = $state('require');

  // Service account
  let bindDN = $state('');
  let bindPassword = $state('');

  // User search
  let searchBase = $state('');
  let mode = $state('activedirectory');
  let searchFilter = $state('({user_attr}={username})');

  // Attribute mapping
  let userAttr = $state('sAMAccountName');
  let mailAttr = $state('mail');
  let groupAttr = $state('memberOf');

  // ── Select options ─────────────────────────────────────────────────────────
  const tlsVerifyOptions = [
    { value: 'none', label: 'None' },
    { value: 'optional', label: 'Optional' },
    { value: 'require', label: 'Require' },
  ];

  const modeOptions = [
    { value: 'activedirectory', label: 'Active Directory' },
    { value: 'openldap', label: 'OpenLDAP' },
  ];

  // ── Reactive: auto-set TLS when URL scheme changes ─────────────────────────
  $effect(() => {
    if (serverUrl.startsWith('ldaps://')) {
      useTLS = true;
      if (port === '389') port = '636';
    }
  });

  // ── Reactive: default attrs when mode changes ──────────────────────────────
  function handleModeChange(event) {
    const val = event.detail?.value ?? event.target?.value ?? mode;
    mode = val;
    if (val === 'activedirectory') {
      userAttr = 'sAMAccountName';
      groupAttr = 'memberOf';
    } else {
      userAttr = 'uid';
      groupAttr = 'memberOf';
    }
  }

  // ── On mount: fetch settings ──────────────────────────────────────────────
  $effect(() => {
    fetchSettings();
  });

  async function fetchSettings() {
    loading = true;
    try {
      const data = await api.get('/settings/ldap');
      const cfg = data.config ?? {};
      fromEnv      = data.from_env ?? {};
      enabled      = cfg.enabled      ?? false;
      serverUrl    = cfg.server       ?? 'ldap://dc.example.com';
      port         = String(cfg.port  ?? 389);
      useTLS       = cfg.tls_enabled  ?? false;
      tlsVerify    = cfg.tls_verify   ?? 'require';
      bindDN       = cfg.bind_dn      ?? '';
      bindPassword = cfg.bind_password ?? '';
      searchBase   = cfg.search_base  ?? '';
      mode         = cfg.mode         ?? 'ldap';
      searchFilter = cfg.search_filter ?? '({user_attr}={username})';
      userAttr     = cfg.user_attr    ?? 'sAMAccountName';
      mailAttr     = cfg.mail_attr    ?? 'mail';
      groupAttr    = cfg.group_attr   ?? 'memberOf';
    } catch {
      // leave defaults
    } finally {
      loading = false;
    }
  }

  function buildPayload() {
    return {
      enabled,
      server:        serverUrl,
      port:          parseInt(port, 10) || 389,
      tls_enabled:   useTLS,
      tls_verify:    tlsVerify,
      bind_dn:       bindDN,
      bind_password: bindPassword,
      search_base:   searchBase,
      mode,
      search_filter: searchFilter,
      user_attr:     userAttr,
      mail_attr:     mailAttr,
      group_attr:    groupAttr,
    };
  }

  async function handleTest() {
    testing = true;
    testResult = null;
    try {
      const data = await api.post('/settings/ldap/test', buildPayload());
      if (data.success) {
        testResult = {
          ok: true,
          message: data.message || (data.user_count != null
            ? `Connected — ${data.user_count} users found`
            : 'Connected successfully'),
        };
      } else {
        testResult = {
          ok: false,
          message: data.error || data.message || 'Connection failed',
        };
      }
    } catch (err) {
      testResult = { ok: false, message: err.message || 'Request failed' };
    } finally {
      testing = false;
    }
  }

  async function handleSave() {
    saving = true;
    saveMsg = '';
    saveError = '';
    try {
      await api.put('/settings/ldap', buildPayload());
      saveMsg = 'Settings saved successfully.';
    } catch (err) {
      saveError = err.message;
    } finally {
      saving = false;
    }
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>LDAP / Active Directory</h3>
    <p>Configure external directory authentication for dashboard login</p>
  </div>

  {#if loading}
    <Card padding="lg">
      <div class="loading">Loading...</div>
    </Card>
  {:else}
    <!-- ── Section 1: Enable/Disable ──────────────────────────────────────── -->
    <Card padding="md">
      <div class="toggle-row">
        <Toggle
          bind:checked={enabled}
          label="Enable LDAP Authentication"
          description="Let users sign in with their directory credentials"
          disabled={isEnvLocked(fromEnv, 'enabled')}
        />
        <EnvBadge locked={isEnvLocked(fromEnv, 'enabled')} />
      </div>
    </Card>

    <!-- ── Section 2: Server ──────────────────────────────────────────────── -->
    <Card padding="md">
      <div class="card-section-title">Server</div>
      <div class="form-group">
        <Input
          bind:value={serverUrl}
          label="LDAP Server URL"
          placeholder="ldap://dc.example.com"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'server')}
        />
      </div>
      <div class="form-row">
        <div class="form-group form-group--port">
          <Input
            bind:value={port}
            label="Port"
            placeholder="389"
            type="number"
            min="1"
            max="65535"
            disabled={!enabled}
            envLocked={isEnvLocked(fromEnv, 'port')}
            fullWidth
          />
        </div>
        <div class="form-group form-group--tls-verify">
          <Select
            bind:value={tlsVerify}
            label="TLS Verify"
            options={tlsVerifyOptions}
            disabled={!enabled || !useTLS}
            envLocked={isEnvLocked(fromEnv, 'tls_verify')}
            fullWidth
          />
        </div>
      </div>
      <div class="toggle-row toggle-row--inline">
        <Toggle
          bind:checked={useTLS}
          label="Use TLS / LDAPS"
          size="sm"
          disabled={!enabled || isEnvLocked(fromEnv, 'tls_enabled')}
        />
        <EnvBadge locked={isEnvLocked(fromEnv, 'tls_enabled')} />
      </div>
    </Card>

    <!-- ── Section 3: Service Account ────────────────────────────────────── -->
    <Card padding="md">
      <div class="card-section-title">Service Account</div>
      <div class="form-group">
        <Input
          bind:value={bindDN}
          label="Bind DN"
          placeholder="CN=svc-purl,DC=corp,DC=com"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'bind_dn')}
          autocomplete="off"
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={bindPassword}
          label="Bind Password"
          type="password"
          placeholder="••••••••••••"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'bind_password')}
          autocomplete="new-password"
        />
      </div>
    </Card>

    <!-- ── Section 4: User Search ─────────────────────────────────────────── -->
    <Card padding="md">
      <div class="card-section-title">User Search</div>
      <div class="form-group">
        <Input
          bind:value={searchBase}
          label="Search Base"
          placeholder="DC=corp,DC=com"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'search_base')}
        />
      </div>
      <div class="form-row">
        <div class="form-group form-group--mode">
          <Select
            bind:value={mode}
            label="Mode"
            options={modeOptions}
            disabled={!enabled}
            envLocked={isEnvLocked(fromEnv, 'mode')}
            fullWidth
            on:change={handleModeChange}
          />
        </div>
        <div class="form-group form-group--filter">
          <Input
            bind:value={searchFilter}
            label="Search Filter"
            placeholder={'({user_attr}={username})'}
            fullWidth
            disabled={!enabled}
            envLocked={isEnvLocked(fromEnv, 'search_filter')}
          />
        </div>
      </div>
    </Card>

    <!-- ── Section 5: Advanced (collapsible) ─────────────────────────────── -->
    <Card padding="md">
      <button
        type="button"
        class="advanced-toggle"
        onclick={() => showAdvanced = !showAdvanced}
      >
        <Icon icon={caretDown} size={12} class="chevron {showAdvanced ? 'open' : ''}" />
        <span>Advanced — Attribute Mapping</span>
      </button>

      {#if showAdvanced}
        <div class="advanced-body">
          <div class="form-row form-row--three">
            <div class="form-group">
              <Input
                bind:value={userAttr}
                label="Username Attribute"
                placeholder="sAMAccountName"
                fullWidth
                disabled={!enabled}
                envLocked={isEnvLocked(fromEnv, 'user_attr')}
              />
            </div>
            <div class="form-group">
              <Input
                bind:value={mailAttr}
                label="Mail Attribute"
                placeholder="mail"
                fullWidth
                disabled={!enabled}
                envLocked={isEnvLocked(fromEnv, 'mail_attr')}
              />
            </div>
            <div class="form-group">
              <Input
                bind:value={groupAttr}
                label="Group Attribute"
                placeholder="memberOf"
                fullWidth
                disabled={!enabled}
                envLocked={isEnvLocked(fromEnv, 'group_attr')}
              />
            </div>
          </div>
        </div>
      {/if}
    </Card>

    <!-- ── Test result ─────────────────────────────────────────────────────── -->
    {#if testResult !== null}
      <div class="test-result" class:test-ok={testResult.ok} class:test-fail={!testResult.ok}>
        {#if testResult.ok}
          <Icon icon={check} size={14} strokeWidth={2.5} />
          Connected — {testResult.message}
        {:else}
          <Icon icon={close} size={14} strokeWidth={2.5} />
          Connection failed: {testResult.message}
        {/if}
      </div>
    {/if}

    <!-- ── Save feedback ───────────────────────────────────────────────────── -->
    {#if saveMsg}
      <div class="save-msg">{saveMsg}</div>
    {/if}
    {#if saveError}
      <div class="error-msg">{saveError}</div>
    {/if}

    <!-- ── Actions row ─────────────────────────────────────────────────────── -->
    <div class="actions-row">
      <Button
        variant="default"
        on:click={handleTest}
        loading={testing}
        disabled={!enabled || saving}
      >
        Test Connection
      </Button>
      <Button
        variant="primary"
        on:click={handleSave}
        loading={saving}
        disabled={testing}
      >
        Save Settings
      </Button>
    </div>
  {/if}
</section>

<style>
  .settings-section {
    max-width: 700px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  /* ── Section header ──────────────────────────────────────────────────────── */
  .section-header {
    margin-bottom: 8px;
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

  /* ── Loading ─────────────────────────────────────────────────────────────── */
  .loading {
    text-align: center;
    color: var(--text-secondary);
    padding: 20px;
  }

  /* ── Card section title ──────────────────────────────────────────────────── */
  .card-section-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    margin-bottom: 14px;
  }

  /* ── Form layout ─────────────────────────────────────────────────────────── */
  .form-group {
    margin-bottom: 12px;
  }

  .form-group:last-child {
    margin-bottom: 0;
  }

  .form-row {
    display: flex;
    gap: 12px;
    margin-bottom: 12px;
  }

  .form-row--three {
    flex-wrap: wrap;
  }

  .form-row--three .form-group {
    flex: 1 1 180px;
    margin-bottom: 0;
  }

  .form-group--port {
    flex: 0 0 110px;
  }

  .form-group--tls-verify {
    flex: 1;
  }

  .form-group--mode {
    flex: 0 0 200px;
  }

  .form-group--filter {
    flex: 1;
  }

  /* ── Toggle rows ─────────────────────────────────────────────────────────── */
  .toggle-row {
    padding: 4px 0;
  }

  .toggle-row--inline {
    margin-top: 10px;
  }

  /* ── Advanced collapsible ────────────────────────────────────────────────── */
  .advanced-toggle {
    display: flex;
    align-items: center;
    gap: 8px;
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    padding: 0;
    transition: color 0.15s ease;
  }

  .advanced-toggle:hover {
    color: var(--text-primary);
  }

  .advanced-toggle :global(.chevron) {
    flex-shrink: 0;
    transition: transform 0.2s ease;
  }

  .advanced-toggle :global(.chevron.open) {
    transform: rotate(180deg);
  }

  .advanced-body {
    margin-top: 16px;
    padding-top: 16px;
    border-top: 1px solid var(--border-color);
  }

  /* ── Test result banner ──────────────────────────────────────────────────── */
  .test-result {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    border-radius: 6px;
    font-size: 0.8125rem;
    font-weight: 500;
  }

  .test-ok {
    background: rgba(35, 134, 54, 0.12);
    border: 1px solid rgba(35, 134, 54, 0.4);
    color: var(--color-success);
  }

  .test-fail {
    background: rgba(248, 81, 73, 0.10);
    border: 1px solid var(--color-error);
    color: var(--color-error);
  }

  /* ── Save messages ───────────────────────────────────────────────────────── */
  .save-msg {
    padding: 10px 14px;
    background: rgba(35, 134, 54, 0.10);
    border: 1px solid rgba(35, 134, 54, 0.35);
    border-radius: 6px;
    color: var(--color-success);
    font-size: 0.8125rem;
  }

  .error-msg {
    padding: 10px 14px;
    background: rgba(248, 81, 73, 0.10);
    border: 1px solid var(--color-error);
    border-radius: 6px;
    color: var(--color-error);
    font-size: 0.8125rem;
  }

  /* ── Actions row ─────────────────────────────────────────────────────────── */
  .actions-row {
    display: flex;
    gap: 10px;
    align-items: center;
    padding-top: 4px;
  }
</style>
