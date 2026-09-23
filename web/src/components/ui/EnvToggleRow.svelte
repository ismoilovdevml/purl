<!--
  EnvToggleRow
  A settings <Toggle> with the <EnvBadge> that says the environment owns the
  key. Used by the SSO and LDAP pages for their enable switch and the smaller
  inline switches inside a card.

  Usage:
  <EnvToggleRow
    bind:checked={form.sign_requests}
    label="Sign Authentication Requests"
    size="sm"
    inline
    disabled={!form.enabled || isEnvLocked(fromEnv, 'sign_requests')}
    locked={isEnvLocked(fromEnv, 'sign_requests')}
  />
-->
<script>
  import Toggle from './Toggle.svelte';
  import EnvBadge from './EnvBadge.svelte';

  let {
    /** Bound checked state */
    checked = $bindable(),
    /** Toggle label */
    label = '',
    /** Toggle description (under the label) */
    description = '',
    /** Toggle size: sm, md */
    size = 'md',
    /** Toggle disabled state (the caller decides, env lock included) */
    disabled = false,
    /** The environment owns this key: show the ENV badge */
    locked = false,
    /** Secondary switch inside a card: adds top spacing */
    inline = false,
  } = $props();
</script>

<div class="toggle-row" class:toggle-row--inline={inline}>
  <Toggle
    bind:checked
    {label}
    {description}
    {size}
    {disabled}
  />
  <EnvBadge {locked} />
</div>

<style>
  .toggle-row {
    padding: 4px 0;
  }

  .toggle-row--inline {
    margin-top: 10px;
  }
</style>
