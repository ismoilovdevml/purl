<!--
  LdapServerCard
  The "Server" card of the LDAP page: server URL, port, TLS verify mode and
  the TLS switch. LDAPSettings owns the values (and the ldaps:// auto-TLS rule).
-->
<script>
  import Card from '../../ui/Card.svelte';
  import Input from '../../ui/Input.svelte';
  import Select from '../../ui/Select.svelte';
  import EnvToggleRow from '../../ui/EnvToggleRow.svelte';
  import { isEnvLocked } from '../../../utils/envLock.js';

  let {
    /** Bound: LDAP server URL */
    server = $bindable(),
    /** Bound: port, as a string (number input) */
    port = $bindable(),
    /** Bound: 'none' | 'optional' | 'require' */
    tlsVerify = $bindable(),
    /** Bound: use TLS / LDAPS */
    tlsEnabled = $bindable(),
    /** LDAP is switched on; every field is disabled otherwise */
    enabled = false,
    /** ldap.* keys the environment owns: { server: 1, ... } */
    fromEnv = {},
  } = $props();

  const tlsVerifyOptions = [
    { value: 'none', label: 'None' },
    { value: 'optional', label: 'Optional' },
    { value: 'require', label: 'Require' },
  ];
</script>

<Card padding="md">
  <div class="card-section-title">Server</div>
  <div class="form-group">
    <Input
      bind:value={server}
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
        disabled={!enabled || !tlsEnabled}
        envLocked={isEnvLocked(fromEnv, 'tls_verify')}
        fullWidth
      />
    </div>
  </div>
  <EnvToggleRow
    bind:checked={tlsEnabled}
    label="Use TLS / LDAPS"
    size="sm"
    inline
    disabled={!enabled || isEnvLocked(fromEnv, 'tls_enabled')}
    locked={isEnvLocked(fromEnv, 'tls_enabled')}
  />
</Card>

<style>
  .card-section-title {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    margin-bottom: 14px;
  }

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

  .form-group--port {
    flex: 0 0 110px;
  }

  .form-group--tls-verify {
    flex: 1;
  }
</style>
