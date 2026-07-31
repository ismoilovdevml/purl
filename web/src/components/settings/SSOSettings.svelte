<!--
  SSOSettings Component
  SAML / SSO authentication configuration (Enterprise only)

  Usage:
  <SSOSettings />
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
  import { lock, caretDown, check, copy, close, arrowRight } from '../ui/icons.js';

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

  // ── Copy state ─────────────────────────────────────────────────────────────
  let copied = $state(false);

  /*
   * Which saml.* keys the environment owns: { idp_sso_url: 1, acs_url: 0, ... }.
   * GET /settings/sso has always sent this map (as `from_env`); this page
   * ignored it, so a field pinned by PURL_SAML_* rendered editable and the save
   * came back 409.
   */
  let fromEnv = $state({});

  // ── Form fields ────────────────────────────────────────────────────────────
  let enabled = $state(false);

  // Identity Provider
  let idpEntityId = $state('');
  let idpSsoUrl = $state('');
  let idpSloUrl = $state('');
  let idpCertificate = $state('');

  // Service Provider
  let spEntityId = $state('');
  let acsUrl = $state('');
  let nameIdFormat = $state('urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress');
  let signRequests = $state(false);
  let spCertificate = $state('');
  let spPrivateKey = $state('');

  // Attribute mapping
  let usernameAttr = $state('http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name');
  let groupsAttr = $state('http://schemas.xmlsoap.org/claims/Group');
  let allowedGroups = $state('');

  // Force authentication
  let forceAuthn = $state(false);

  // ── Select options ─────────────────────────────────────────────────────────
  const nameIdFormatOptions = [
    { value: 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress', label: 'Email Address' },
    { value: 'urn:oasis:names:tc:SAML:2.0:nameid-format:persistent', label: 'Persistent' },
    { value: 'urn:oasis:names:tc:SAML:2.0:nameid-format:transient', label: 'Transient' },
    { value: 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified', label: 'Unspecified' },
  ];

  // ── Derived: SP Metadata URL ──────────────────────────────────────────────
  const metadataUrl = $derived(
    spEntityId
      ? `${window.location.origin}/api/auth/saml/metadata`
      : ''
  );

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
      const data = await api.get('/settings/sso');
      const cfg = data.config ?? {};
      fromEnv        = data.from_env       ?? {};
      /*
       * Key names are the saml.* config keys, NOT prettier aliases. This page
       * used to read idp_certificate / sp_entity_id / sp_certificate /
       * sp_private_key, none of which the API sends or accepts (they are
       * idp_cert / entity_id / sp_cert / sp_key), so every one of those four
       * fields loaded blank and never saved — and with entity_id missing, the
       * server rejected any attempt to enable SSO at all.
       */
      enabled        = cfg.enabled         ?? false;
      idpEntityId    = cfg.idp_entity_id   ?? '';
      idpSsoUrl      = cfg.idp_sso_url     ?? '';
      idpSloUrl      = cfg.idp_slo_url     ?? '';
      idpCertificate = cfg.idp_cert        ?? '';
      spEntityId     = cfg.entity_id       ?? '';
      acsUrl         = cfg.acs_url         ?? '';
      nameIdFormat   = cfg.name_id_format  ?? 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress';
      signRequests   = cfg.sign_requests   ?? false;
      spCertificate  = cfg.sp_cert         ?? '';
      spPrivateKey   = cfg.sp_key          ?? '';
      usernameAttr   = cfg.username_attr   ?? 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name';
      groupsAttr     = cfg.groups_attr     ?? 'http://schemas.xmlsoap.org/claims/Group';
      allowedGroups  = cfg.allowed_groups  ?? '';
      forceAuthn     = cfg.force_authn     ?? false;
    } catch {
      // leave defaults
    } finally {
      loading = false;
    }
  }

  function buildPayload() {
    return {
      enabled,
      idp_entity_id:  idpEntityId,
      idp_sso_url:    idpSsoUrl,
      idp_slo_url:    idpSloUrl,
      idp_cert:       idpCertificate,
      entity_id:      spEntityId,
      acs_url:        acsUrl,
      name_id_format: nameIdFormat,
      sign_requests:  signRequests,
      sp_cert:        spCertificate,
      sp_key:         spPrivateKey,
      username_attr:  usernameAttr,
      groups_attr:    groupsAttr,
      allowed_groups: allowedGroups,
      force_authn:    forceAuthn,
    };
  }

  async function handleTest() {
    testing = true;
    testResult = null;
    try {
      const data = await api.post('/settings/sso/test', buildPayload());
      if (data.success) {
        testResult = {
          ok: true,
          message: data.message || 'SSO configuration is valid',
        };
      } else {
        testResult = {
          ok: false,
          message: data.error || data.message || 'Configuration validation failed',
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
      await api.put('/settings/sso', buildPayload());
      saveMsg = 'Settings saved successfully.';
    } catch (err) {
      saveError = err.message;
    } finally {
      saving = false;
    }
  }

  function copyMetadataUrl() {
    if (!metadataUrl) return;
    navigator.clipboard.writeText(metadataUrl).then(() => {
      copied = true;
      setTimeout(() => { copied = false; }, 2000);
    });
  }

  const isEnterprise = $derived(plan === 'enterprise');
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>SAML / SSO</h3>
    <p>Configure single sign-on via SAML 2.0 identity providers</p>
  </div>

  {#if licenseLoading || loading}
    <Card padding="lg">
      <div class="loading">Loading...</div>
    </Card>
  {:else if !isEnterprise}
    <!-- Enterprise gate banner -->
    <div class="enterprise-banner">
      <div class="banner-icon">
        <Icon icon={lock} size={20} />
      </div>
      <div class="banner-body">
        <strong>SAML / SSO requires an Enterprise license.</strong>
        <p>Upgrade to enable single sign-on via SAML 2.0 identity providers like Okta, Azure AD, or OneLogin.</p>
      </div>
      <div class="banner-actions">
        <a href="https://purl.dev/pricing" class="upgrade-link" target="_blank" rel="noopener noreferrer">
          Upgrade to Enterprise
          <Icon icon={arrowRight} size={12} strokeWidth={3} />
        </a>
        <a href="https://purlogs.com/docs" class="docs-link" target="_blank" rel="noopener noreferrer">
          How SAML SSO works
        </a>
      </div>
    </div>
  {:else}
    <!-- ── Section 1: Enable/Disable ──────────────────────────────────────── -->
    <Card padding="md">
      <div class="toggle-row">
        <Toggle
          bind:checked={enabled}
          label="Enable SAML SSO"
          description="Requires Enterprise license"
          disabled={isEnvLocked(fromEnv, 'enabled')}
        />
        <EnvBadge locked={isEnvLocked(fromEnv, 'enabled')} />
      </div>
    </Card>

    <!-- ── Section 2: Identity Provider ───────────────────────────────────── -->
    <Card padding="md">
      <div class="card-section-title">Identity Provider</div>
      <div class="form-group">
        <Input
          bind:value={idpEntityId}
          label="IdP Entity ID"
          placeholder="https://idp.example.com/metadata"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'idp_entity_id')}
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={idpSsoUrl}
          label="IdP SSO URL"
          placeholder="https://idp.example.com/sso/saml"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'idp_sso_url')}
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={idpSloUrl}
          label="IdP SLO URL (optional)"
          placeholder="https://idp.example.com/slo/saml"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'idp_slo_url')}
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={idpCertificate}
          label="IdP Certificate (PEM)"
          type="textarea"
          placeholder="-----BEGIN CERTIFICATE-----&#10;...&#10;-----END CERTIFICATE-----"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'idp_cert')}
        />
      </div>
    </Card>

    <!-- ── Section 3: Service Provider ────────────────────────────────────── -->
    <Card padding="md">
      <div class="card-section-title">Service Provider</div>
      <div class="form-group">
        <Input
          bind:value={spEntityId}
          label="SP Entity ID"
          placeholder="https://purl.example.com"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'entity_id')}
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={acsUrl}
          label="Assertion Consumer Service (ACS) URL"
          placeholder="https://purl.example.com/api/auth/saml/acs"
          fullWidth
          disabled={!enabled}
          envLocked={isEnvLocked(fromEnv, 'acs_url')}
        />
      </div>
      <div class="form-row">
        <div class="form-group form-group--nameid">
          <Select
            bind:value={nameIdFormat}
            label="NameID Format"
            options={nameIdFormatOptions}
            disabled={!enabled}
            envLocked={isEnvLocked(fromEnv, 'name_id_format')}
            fullWidth
          />
        </div>
      </div>
      <div class="toggle-row toggle-row--inline">
        <Toggle
          bind:checked={signRequests}
          label="Sign Authentication Requests"
          size="sm"
          disabled={!enabled || isEnvLocked(fromEnv, 'sign_requests')}
        />
        <EnvBadge locked={isEnvLocked(fromEnv, 'sign_requests')} />
      </div>
      <div class="toggle-row toggle-row--inline">
        <Toggle
          bind:checked={forceAuthn}
          label="Force Authentication"
          size="sm"
          disabled={!enabled || isEnvLocked(fromEnv, 'force_authn')}
        />
        <EnvBadge locked={isEnvLocked(fromEnv, 'force_authn')} />
      </div>
    </Card>

    <!-- ── Section 4: SP Metadata URL ─────────────────────────────────────── -->
    {#if metadataUrl}
      <Card padding="md">
        <div class="card-section-title">SP Metadata</div>
        <div class="metadata-row">
          <code class="metadata-url">{metadataUrl}</code>
          <button
            type="button"
            class="copy-btn"
            onclick={copyMetadataUrl}
            title="Copy metadata URL"
            aria-label="Copy SP metadata URL"
          >
            {#if copied}
              <Icon icon={check} size={14} strokeWidth={2.5} />
            {:else}
              <Icon icon={copy} size={14} strokeWidth={2.5} />
            {/if}
          </button>
        </div>
        <p class="metadata-hint">Provide this URL to your identity provider for automatic SP configuration.</p>
      </Card>
    {/if}

    <!-- ── Section 5: Advanced (collapsible) ─────────────────────────────── -->
    <Card padding="md">
      <button
        type="button"
        class="advanced-toggle"
        onclick={() => showAdvanced = !showAdvanced}
      >
        <Icon icon={caretDown} size={12} class="chevron {showAdvanced ? 'open' : ''}" />
        <span>Advanced — Attribute Mapping &amp; SP Certificates</span>
      </button>

      {#if showAdvanced}
        <div class="advanced-body">
          <div class="form-row form-row--three">
            <div class="form-group">
              <Input
                bind:value={usernameAttr}
                label="Username Attribute"
                placeholder="http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"
                fullWidth
                disabled={!enabled}
                envLocked={isEnvLocked(fromEnv, 'username_attr')}
              />
            </div>
            <div class="form-group">
              <Input
                bind:value={groupsAttr}
                label="Groups Attribute"
                placeholder="http://schemas.xmlsoap.org/claims/Group"
                fullWidth
                disabled={!enabled}
                envLocked={isEnvLocked(fromEnv, 'groups_attr')}
              />
            </div>
          </div>
          <div class="form-group">
            <Input
              bind:value={allowedGroups}
              label="Allowed Groups"
              placeholder="Comma-separated group names (leave empty for all)"
              fullWidth
              disabled={!enabled}
              envLocked={isEnvLocked(fromEnv, 'allowed_groups')}
              helper="Only users in these groups will be allowed to log in. Leave empty to allow all."
            />
          </div>
          <div class="form-group">
            <Input
              bind:value={spCertificate}
              label="SP Certificate (PEM, optional)"
              type="textarea"
              placeholder="-----BEGIN CERTIFICATE-----&#10;...&#10;-----END CERTIFICATE-----"
              fullWidth
              disabled={!enabled}
              envLocked={isEnvLocked(fromEnv, 'sp_cert')}
              helper="Required if Sign Requests is enabled."
            />
          </div>
          <div class="form-group">
            <Input
              bind:value={spPrivateKey}
              label="SP Private Key (PEM, optional)"
              type="textarea"
              placeholder="-----BEGIN PRIVATE KEY-----&#10;...&#10;-----END PRIVATE KEY-----"
              fullWidth
              disabled={!enabled}
              envLocked={isEnvLocked(fromEnv, 'sp_key')}
              helper="Required if Sign Requests is enabled. Stored securely on server."
            />
          </div>
        </div>
      {/if}
    </Card>

    <!-- ── Test result ─────────────────────────────────────────────────────── -->
    {#if testResult !== null}
      <div class="test-result" class:test-ok={testResult.ok} class:test-fail={!testResult.ok}>
        {#if testResult.ok}
          <Icon icon={check} size={14} strokeWidth={2.5} />
          Valid — {testResult.message}
        {:else}
          <Icon icon={close} size={14} strokeWidth={2.5} />
          Validation failed: {testResult.message}
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
        Test Configuration
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
    color: var(--color-primary);
  }

  .banner-body {
    flex: 1;
    min-width: 0;
  }

  .banner-body strong {
    display: block;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-bright);
    margin-bottom: 4px;
  }

  .banner-body p {
    margin: 0;
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .banner-actions {
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 6px;
  }

  .upgrade-link {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 14px;
    background: var(--color-primary);
    color: #ffffff;
    font-size: 0.8125rem;
    font-weight: 500;
    text-decoration: none;
    border-radius: 6px;
    white-space: nowrap;
    transition: background 0.15s ease;
  }

  .upgrade-link:hover {
    background: var(--color-primary-hover);
  }

  /* Secondary path: help, not checkout. */
  .docs-link {
    font-size: 0.75rem;
    color: var(--text-secondary);
    text-decoration: none;
    white-space: nowrap;
    transition: color 0.15s ease;
  }

  .docs-link:hover {
    color: var(--color-primary);
    text-decoration: underline;
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
    flex: 1 1 220px;
    margin-bottom: 0;
  }

  .form-group--nameid {
    flex: 1;
  }

  /* ── Toggle rows ─────────────────────────────────────────────────────────── */
  .toggle-row {
    padding: 4px 0;
  }

  .toggle-row--inline {
    margin-top: 10px;
  }

  /* ── SP Metadata URL ─────────────────────────────────────────────────────── */
  .metadata-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 8px;
  }

  .metadata-url {
    flex: 1;
    min-width: 0;
    padding: 8px 12px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    font-size: 0.8125rem;
    color: var(--text-primary);
    font-family: var(--font-mono);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .copy-btn {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-secondary);
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .copy-btn:hover {
    color: var(--text-primary);
    border-color: var(--text-secondary);
  }

  .metadata-hint {
    margin: 0;
    font-size: 0.75rem;
    color: var(--text-muted);
    line-height: 1.5;
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
