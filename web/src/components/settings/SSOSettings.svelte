<!--
  SSOSettings Component
  SAML / SSO authentication configuration

  Usage:
  <SSOSettings />
-->
<script>
  import Card from '../ui/Card.svelte';
  import Input from '../ui/Input.svelte';
  import Select from '../ui/Select.svelte';
  import EnvToggleRow from '../ui/EnvToggleRow.svelte';
  import AdvancedDisclosure from '../ui/AdvancedDisclosure.svelte';
  import ConnectionTestFooter from '../ui/ConnectionTestFooter.svelte';
  import SsoMetadataCard from './sso/SsoMetadataCard.svelte';
  import { api } from '../../utils/api.js';
  import { isEnvLocked } from '../../utils/envLock.js';
  import { runConnectionTest } from '../../utils/connectionTest.js';
  import { formFromConfig } from '../../utils/settingsForm.js';

  // ── Page state ─────────────────────────────────────────────────────────────
  let loading = $state(true);
  let saveMsg = $state('');
  let saveError = $state('');
  let saving = $state(false);

  // ── Test connection state ──────────────────────────────────────────────────
  let testing = $state(false);
  let testResult = $state(null); // null | { ok: boolean, message: string }

  /*
   * Which saml.* keys the environment owns: { idp_sso_url: 1, acs_url: 0, ... }.
   * GET /settings/sso has always sent this map (as `from_env`); this page
   * ignored it, so a field pinned by PURL_SAML_* rendered editable and the save
   * came back 409.
   */
  let fromEnv = $state({});

  /*
   * Form fields, keyed by the saml.* config keys, NOT prettier aliases. This
   * page used to read idp_certificate / sp_entity_id / sp_certificate /
   * sp_private_key, none of which the API sends or accepts (they are
   * idp_cert / entity_id / sp_cert / sp_key), so every one of those four
   * fields loaded blank and never saved — and with entity_id missing, the
   * server rejected any attempt to enable SSO at all.
   *
   * Grouped as on screen (IdP, SP, attribute mapping); the order is the
   * order of the PUT / test payload.
   */
  const DEFAULTS = {
    enabled: false,
    idp_entity_id: '',
    idp_sso_url: '',
    idp_slo_url: '',
    idp_cert: '',
    entity_id: '',
    acs_url: '',
    name_id_format: 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress',
    sign_requests: false,
    sp_cert: '',
    sp_key: '',
    username_attr: 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name',
    groups_attr: 'http://schemas.xmlsoap.org/claims/Group',
    allowed_groups: '',
    force_authn: false,
  };

  let form = $state({ ...DEFAULTS });

  // ── Select options ─────────────────────────────────────────────────────────
  const nameIdFormatOptions = [
    { value: 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress', label: 'Email Address' },
    { value: 'urn:oasis:names:tc:SAML:2.0:nameid-format:persistent', label: 'Persistent' },
    { value: 'urn:oasis:names:tc:SAML:2.0:nameid-format:transient', label: 'Transient' },
    { value: 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified', label: 'Unspecified' },
  ];

  // ── On mount: fetch settings ──────────────────────────────────────────────
  $effect(() => {
    fetchSettings();
  });

  async function fetchSettings() {
    loading = true;
    try {
      const data = await api.get('/settings/sso');
      fromEnv = data.from_env ?? {};
      form = formFromConfig(DEFAULTS, data.config);
    } catch {
      // leave defaults
    } finally {
      loading = false;
    }
  }

  const buildPayload = () => ({ ...form });

  async function handleTest() {
    testing = true;
    testResult = null;
    testResult = await runConnectionTest('/settings/sso/test', buildPayload(), {
      ok: () => 'SSO configuration is valid',
      fail: 'Configuration validation failed',
    });
    testing = false;
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
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>SAML / SSO</h3>
    <p>Configure single sign-on via SAML 2.0 identity providers</p>
  </div>

  {#if loading}
    <Card padding="lg">
      <div class="loading">Loading...</div>
    </Card>
  {:else}
    <!-- ── Section 1: Enable/Disable ──────────────────────────────────────── -->
    <Card padding="md">
      <EnvToggleRow
        bind:checked={form.enabled}
        label="Enable SAML SSO"
        description="Let users sign in through your SAML 2.0 identity provider"
        disabled={isEnvLocked(fromEnv, 'enabled')}
        locked={isEnvLocked(fromEnv, 'enabled')}
      />
    </Card>

    <!-- ── Section 2: Identity Provider ───────────────────────────────────── -->
    <Card padding="md">
      <div class="card-section-title">Identity Provider</div>
      <div class="form-group">
        <Input
          bind:value={form.idp_entity_id}
          label="IdP Entity ID"
          placeholder="https://idp.example.com/metadata"
          fullWidth
          disabled={!form.enabled}
          envLocked={isEnvLocked(fromEnv, 'idp_entity_id')}
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={form.idp_sso_url}
          label="IdP SSO URL"
          placeholder="https://idp.example.com/sso/saml"
          fullWidth
          disabled={!form.enabled}
          envLocked={isEnvLocked(fromEnv, 'idp_sso_url')}
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={form.idp_slo_url}
          label="IdP SLO URL (optional)"
          placeholder="https://idp.example.com/slo/saml"
          fullWidth
          disabled={!form.enabled}
          envLocked={isEnvLocked(fromEnv, 'idp_slo_url')}
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={form.idp_cert}
          label="IdP Certificate (PEM)"
          type="textarea"
          placeholder="-----BEGIN CERTIFICATE-----&#10;...&#10;-----END CERTIFICATE-----"
          fullWidth
          disabled={!form.enabled}
          envLocked={isEnvLocked(fromEnv, 'idp_cert')}
        />
      </div>
    </Card>

    <!-- ── Section 3: Service Provider ────────────────────────────────────── -->
    <Card padding="md">
      <div class="card-section-title">Service Provider</div>
      <div class="form-group">
        <Input
          bind:value={form.entity_id}
          label="SP Entity ID"
          placeholder="https://purl.example.com"
          fullWidth
          disabled={!form.enabled}
          envLocked={isEnvLocked(fromEnv, 'entity_id')}
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={form.acs_url}
          label="Assertion Consumer Service (ACS) URL"
          placeholder="https://purl.example.com/api/auth/saml/acs"
          fullWidth
          disabled={!form.enabled}
          envLocked={isEnvLocked(fromEnv, 'acs_url')}
        />
      </div>
      <div class="form-row">
        <div class="form-group form-group--nameid">
          <Select
            bind:value={form.name_id_format}
            label="NameID Format"
            options={nameIdFormatOptions}
            disabled={!form.enabled}
            envLocked={isEnvLocked(fromEnv, 'name_id_format')}
            fullWidth
          />
        </div>
      </div>
      <EnvToggleRow
        bind:checked={form.sign_requests}
        label="Sign Authentication Requests"
        size="sm"
        inline
        disabled={!form.enabled || isEnvLocked(fromEnv, 'sign_requests')}
        locked={isEnvLocked(fromEnv, 'sign_requests')}
      />
      <EnvToggleRow
        bind:checked={form.force_authn}
        label="Force Authentication"
        size="sm"
        inline
        disabled={!form.enabled || isEnvLocked(fromEnv, 'force_authn')}
        locked={isEnvLocked(fromEnv, 'force_authn')}
      />
    </Card>

    <!-- ── Section 4: SP Metadata URL ─────────────────────────────────────── -->
    <SsoMetadataCard spEntityId={form.entity_id} />

    <!-- ── Section 5: Advanced (collapsible) ─────────────────────────────── -->
    <Card padding="md">
      <AdvancedDisclosure label="Advanced — Attribute Mapping & SP Certificates">
        <div class="form-row form-row--three">
          <div class="form-group">
            <Input
              bind:value={form.username_attr}
              label="Username Attribute"
              placeholder="http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"
              fullWidth
              disabled={!form.enabled}
              envLocked={isEnvLocked(fromEnv, 'username_attr')}
            />
          </div>
          <div class="form-group">
            <Input
              bind:value={form.groups_attr}
              label="Groups Attribute"
              placeholder="http://schemas.xmlsoap.org/claims/Group"
              fullWidth
              disabled={!form.enabled}
              envLocked={isEnvLocked(fromEnv, 'groups_attr')}
            />
          </div>
        </div>
        <div class="form-group">
          <Input
            bind:value={form.allowed_groups}
            label="Allowed Groups"
            placeholder="Comma-separated group names (leave empty for all)"
            fullWidth
            disabled={!form.enabled}
            envLocked={isEnvLocked(fromEnv, 'allowed_groups')}
            helper="Only users in these groups will be allowed to log in. Leave empty to allow all."
          />
        </div>
        <div class="form-group">
          <Input
            bind:value={form.sp_cert}
            label="SP Certificate (PEM, optional)"
            type="textarea"
            placeholder="-----BEGIN CERTIFICATE-----&#10;...&#10;-----END CERTIFICATE-----"
            fullWidth
            disabled={!form.enabled}
            envLocked={isEnvLocked(fromEnv, 'sp_cert')}
            helper="Required if Sign Requests is enabled."
          />
        </div>
        <div class="form-group">
          <Input
            bind:value={form.sp_key}
            label="SP Private Key (PEM, optional)"
            type="textarea"
            placeholder="-----BEGIN PRIVATE KEY-----&#10;...&#10;-----END PRIVATE KEY-----"
            fullWidth
            disabled={!form.enabled}
            envLocked={isEnvLocked(fromEnv, 'sp_key')}
            helper="Required if Sign Requests is enabled. Stored securely on server."
          />
        </div>
      </AdvancedDisclosure>
    </Card>

    <!-- ── Test result, save feedback, actions ─────────────────────────────── -->
    <ConnectionTestFooter
      {testResult}
      {testing}
      {saving}
      {saveMsg}
      {saveError}
      enabled={form.enabled}
      testLabel="Test Configuration"
      okPrefix="Valid"
      failPrefix="Validation failed"
      ontest={handleTest}
      onsave={handleSave}
    />
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
    flex: 1 1 220px;
    margin-bottom: 0;
  }

  .form-group--nameid {
    flex: 1;
  }
</style>
