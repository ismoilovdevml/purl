<!--
  LDAPSettings Component
  LDAP / Active Directory authentication configuration (Enterprise only)

  Usage:
  <LDAPSettings />
-->
<script>
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';
  import Input from '../ui/Input.svelte';
  import Select from '../ui/Select.svelte';
  import Toggle from '../ui/Toggle.svelte';
  import { api } from '../../utils/api.js';
  import Icon from '../ui/Icon.svelte';

  // ── License gate ──────────────────────────────────────────────────────────
  let plan = $state('free');
  let licenseLoading = $state(true);

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

  // ── On mount: fetch license + settings ────────────────────────────────────
  $effect(() => {
    fetchLicense();
    fetchSettings();
  });

  async function fetchLicense() {
    licenseLoading = true;
    try {
      const data = await api.get('/license');
      plan = data.plan || 'free';
    } catch {
      plan = 'free';
    } finally {
      licenseLoading = false;
    }
  }

  async function fetchSettings() {
    loading = true;
    try {
      const data = await api.get('/settings/ldap');
      const cfg = data.config ?? {};
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

  const isEnterprise = $derived(plan === 'enterprise');
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>LDAP / Active Directory</h3>
    <p>Configure external directory authentication for dashboard login</p>
  </div>

  {#if licenseLoading || loading}
    <Card padding="lg">
      <div class="loading">Loading...</div>
    </Card>
  {:else if !isEnterprise}
    <!-- Enterprise gate banner -->
    <div class="enterprise-banner">
      <div class="banner-icon">
        <Icon name="lock" size={20} />
      </div>
      <div class="banner-body">
        <strong>LDAP authentication requires an Enterprise license.</strong>
        <p>Upgrade to enable single sign-on via LDAP or Active Directory for your team.</p>
      </div>
      <a href="https://purl.dev/pricing" class="upgrade-link" target="_blank" rel="noopener noreferrer">
        Upgrade to Enterprise &rarr;
      </a>
    </div>
  {:else}
    <!-- ── Section 1: Enable/Disable ──────────────────────────────────────── -->
    <Card padding="md">
      <div class="toggle-row">
        <Toggle
          bind:checked={enabled}
          label="Enable LDAP Authentication"
          description="Requires Enterprise license"
        />
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
            fullWidth
          />
        </div>
        <div class="form-group form-group--tls-verify">
          <Select
            bind:value={tlsVerify}
            label="TLS Verify"
            options={tlsVerifyOptions}
            disabled={!enabled || !useTLS}
            fullWidth
          />
        </div>
      </div>
      <div class="toggle-row toggle-row--inline">
        <Toggle
          bind:checked={useTLS}
          label="Use TLS / LDAPS"
          size="sm"
          disabled={!enabled}
        />
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
        />
      </div>
      <div class="form-row">
        <div class="form-group form-group--mode">
          <Select
            bind:value={mode}
            label="Mode"
            options={modeOptions}
            disabled={!enabled}
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
        <Icon name="chevron-down" size={14} class="chevron {showAdvanced ? 'open' : ''}" />
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
              />
            </div>
            <div class="form-group">
              <Input
                bind:value={mailAttr}
                label="Mail Attribute"
                placeholder="mail"
                fullWidth
                disabled={!enabled}
              />
            </div>
            <div class="form-group">
              <Input
                bind:value={groupAttr}
                label="Group Attribute"
                placeholder="memberOf"
                fullWidth
                disabled={!enabled}
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
          <Icon name="check" size={14} />
          Connected — {testResult.message}
        {:else}
          <Icon name="close" size={14} />
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
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  /* ── Loading ─────────────────────────────────────────────────────────────── */
  .loading {
    text-align: center;
    color: var(--text-secondary, #8b949e);
    padding: 20px;
  }

  /* ── Enterprise gate banner ──────────────────────────────────────────────── */
  .enterprise-banner {
    display: flex;
    align-items: flex-start;
    gap: 16px;
    padding: 20px;
    background: rgba(88, 166, 255, 0.06);
    border: 1px solid rgba(88, 166, 255, 0.25);
    border-radius: 8px;
  }

  .banner-icon {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    background: rgba(88, 166, 255, 0.12);
    border-radius: 8px;
    color: var(--color-primary, #58a6ff);
  }

  .banner-body {
    flex: 1;
    min-width: 0;
  }

  .banner-body strong {
    display: block;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
    margin-bottom: 4px;
  }

  .banner-body p {
    margin: 0;
    font-size: 0.8125rem;
    color: var(--text-secondary, #8b949e);
    line-height: 1.5;
  }

  .upgrade-link {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    padding: 6px 14px;
    background: var(--color-primary, #58a6ff);
    color: #ffffff;
    font-size: 0.8125rem;
    font-weight: 500;
    text-decoration: none;
    border-radius: 6px;
    white-space: nowrap;
    transition: background 0.15s ease;
  }

  .upgrade-link:hover {
    background: var(--color-primary-hover, #79b8ff);
  }

  /* ── Card section title ──────────────────────────────────────────────────── */
  .card-section-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-secondary, #8b949e);
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
    color: var(--text-secondary, #8b949e);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    padding: 0;
    transition: color 0.15s ease;
  }

  .advanced-toggle:hover {
    color: var(--text-primary, #c9d1d9);
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
    border-top: 1px solid var(--border-color, #30363d);
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
    color: var(--color-success, #3fb950);
  }

  .test-fail {
    background: rgba(248, 81, 73, 0.10);
    border: 1px solid var(--color-error, #f85149);
    color: var(--color-error, #f85149);
  }

  /* ── Save messages ───────────────────────────────────────────────────────── */
  .save-msg {
    padding: 10px 14px;
    background: rgba(35, 134, 54, 0.10);
    border: 1px solid rgba(35, 134, 54, 0.35);
    border-radius: 6px;
    color: var(--color-success, #3fb950);
    font-size: 0.8125rem;
  }

  .error-msg {
    padding: 10px 14px;
    background: rgba(248, 81, 73, 0.10);
    border: 1px solid var(--color-error, #f85149);
    border-radius: 6px;
    color: var(--color-error, #f85149);
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
