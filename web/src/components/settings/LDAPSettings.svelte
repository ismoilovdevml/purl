<!--
  LDAPSettings Component
  LDAP / Active Directory authentication configuration

  Usage:
  <LDAPSettings />
-->
<script>
  import Card from '../ui/Card.svelte';
  import Input from '../ui/Input.svelte';
  import Select from '../ui/Select.svelte';
  import EnvToggleRow from '../ui/EnvToggleRow.svelte';
  import AdvancedDisclosure from '../ui/AdvancedDisclosure.svelte';
  import ConnectionTestFooter from '../ui/ConnectionTestFooter.svelte';
  import LdapServerCard from './ldap/LdapServerCard.svelte';
  import { api } from '../../utils/api.js';
  import { isEnvLocked, optionsIncluding } from '../../utils/envLock.js';
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
   * Which ldap.* keys the environment owns: { server: 1, bind_dn: 0, ... }.
   * GET /settings/ldap has always sent this map (as `from_env`); this page
   * ignored it, so a field pinned by PURL_LDAP_* rendered editable and the save
   * came back 409.
   */
  let fromEnv = $state({});

  /*
   * Form fields, keyed by the ldap.* config keys, in payload order. `port` is
   * kept as a string for the number input and parsed on the way out.
   */
  const DEFAULTS = {
    enabled: false,
    server: 'ldap://dc.example.com',
    port: '389',
    tls_enabled: false,
    tls_verify: 'require',
    bind_dn: '',
    bind_password: '',
    search_base: '',
    mode: 'ldap',
    search_filter: '({user_attr}={username})',
    user_attr: 'uid',
    mail_attr: 'mail',
    group_attr: 'memberOf',
  };

  let form = $state({ ...DEFAULTS });

  // ── Select options ─────────────────────────────────────────────────────────
  /*
   * The values the backend acts on: Middleware/LDAP.pm reads groups the
   * Active Directory way only for mode 'ad' and treats every other value as
   * OpenLDAP; 'ldap' is the server default (Config/Defaults.pm). This page
   * used to offer 'activedirectory', which the backend never recognised, and
   * loaded an unset mode as 'ldap', which matched no option.
   */
  const MODE_OPTIONS = [
    { value: 'ad', label: 'Active Directory' },
    { value: 'ldap', label: 'OpenLDAP' },
  ];

  /**
   * Map a stored mode onto one of MODE_OPTIONS the way the backend reads it.
   * 'activedirectory' is what this page used to save for "Active Directory".
   * @param {string | undefined} mode - Stored ldap.mode
   * @returns {'ad' | 'ldap'}
   */
  function normalizeMode(mode) {
    const m = String(mode ?? '').toLowerCase();
    return m === 'ad' || m === 'activedirectory' ? 'ad' : 'ldap';
  }

  // An ENV-pinned mode is kept verbatim (see optionsIncluding).
  const modeOptions = $derived(optionsIncluding(MODE_OPTIONS, form.mode));

  // ── Reactive: auto-set TLS when URL scheme changes ─────────────────────────
  $effect(() => {
    if (form.server.startsWith('ldaps://')) {
      form.tls_enabled = true;
      if (form.port === '389') form.port = '636';
    }
  });

  // ── Reactive: default attrs when mode changes ──────────────────────────────
  function handleModeChange({ value }) {
    form.mode = value;
    if (value === 'ad') {
      form.user_attr = 'sAMAccountName';
      form.group_attr = 'memberOf';
    } else {
      form.user_attr = 'uid';
      form.group_attr = 'memberOf';
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
      fromEnv = data.from_env ?? {};
      const loaded = formFromConfig(DEFAULTS, data.config);
      if (!isEnvLocked(fromEnv, 'mode')) loaded.mode = normalizeMode(loaded.mode);
      form = loaded;
    } catch {
      // leave defaults
    } finally {
      loading = false;
    }
  }

  function buildPayload() {
    return { ...form, port: parseInt(form.port, 10) || 389 };
  }

  async function handleTest() {
    testing = true;
    testResult = null;
    testResult = await runConnectionTest('/settings/ldap/test', buildPayload(), {
      ok: (data) => (data.user_count != null
        ? `Connected — ${data.user_count} users found`
        : 'Connected successfully'),
      fail: 'Connection failed',
    });
    testing = false;
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
      <EnvToggleRow
        bind:checked={form.enabled}
        label="Enable LDAP Authentication"
        description="Let users sign in with their directory credentials"
        disabled={isEnvLocked(fromEnv, 'enabled')}
        locked={isEnvLocked(fromEnv, 'enabled')}
      />
    </Card>

    <!-- ── Section 2: Server ──────────────────────────────────────────────── -->
    <LdapServerCard
      bind:server={form.server}
      bind:port={form.port}
      bind:tlsVerify={form.tls_verify}
      bind:tlsEnabled={form.tls_enabled}
      enabled={form.enabled}
      {fromEnv}
    />

    <!-- ── Section 3: Service Account ────────────────────────────────────── -->
    <Card padding="md">
      <div class="card-section-title">Service Account</div>
      <div class="form-group">
        <Input
          bind:value={form.bind_dn}
          label="Bind DN"
          placeholder="CN=svc-purl,DC=corp,DC=com"
          fullWidth
          disabled={!form.enabled}
          envLocked={isEnvLocked(fromEnv, 'bind_dn')}
          autocomplete="off"
        />
      </div>
      <div class="form-group">
        <Input
          bind:value={form.bind_password}
          label="Bind Password"
          type="password"
          placeholder="••••••••••••"
          fullWidth
          disabled={!form.enabled}
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
          bind:value={form.search_base}
          label="Search Base"
          placeholder="DC=corp,DC=com"
          fullWidth
          disabled={!form.enabled}
          envLocked={isEnvLocked(fromEnv, 'search_base')}
        />
      </div>
      <div class="form-row">
        <div class="form-group form-group--mode">
          <Select
            bind:value={form.mode}
            label="Mode"
            options={modeOptions}
            disabled={!form.enabled}
            envLocked={isEnvLocked(fromEnv, 'mode')}
            fullWidth
            onchange={handleModeChange}
          />
        </div>
        <div class="form-group form-group--filter">
          <Input
            bind:value={form.search_filter}
            label="Search Filter"
            placeholder={'({user_attr}={username})'}
            fullWidth
            disabled={!form.enabled}
            envLocked={isEnvLocked(fromEnv, 'search_filter')}
          />
        </div>
      </div>
    </Card>

    <!-- ── Section 5: Advanced (collapsible) ─────────────────────────────── -->
    <Card padding="md">
      <AdvancedDisclosure label="Advanced — Attribute Mapping">
        <div class="form-row form-row--three">
          <div class="form-group">
            <Input
              bind:value={form.user_attr}
              label="Username Attribute"
              placeholder="sAMAccountName"
              fullWidth
              disabled={!form.enabled}
              envLocked={isEnvLocked(fromEnv, 'user_attr')}
            />
          </div>
          <div class="form-group">
            <Input
              bind:value={form.mail_attr}
              label="Mail Attribute"
              placeholder="mail"
              fullWidth
              disabled={!form.enabled}
              envLocked={isEnvLocked(fromEnv, 'mail_attr')}
            />
          </div>
          <div class="form-group">
            <Input
              bind:value={form.group_attr}
              label="Group Attribute"
              placeholder="memberOf"
              fullWidth
              disabled={!form.enabled}
              envLocked={isEnvLocked(fromEnv, 'group_attr')}
            />
          </div>
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
      testLabel="Test Connection"
      okPrefix="Connected"
      failPrefix="Connection failed"
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
    flex: 1 1 180px;
    margin-bottom: 0;
  }

  .form-group--mode {
    flex: 0 0 200px;
  }

  .form-group--filter {
    flex: 1;
  }

</style>
