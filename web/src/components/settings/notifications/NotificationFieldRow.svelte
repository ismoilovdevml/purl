<!--
  NotificationFieldRow
  One labelled field of an alert channel. Optionally carries the ENV badge
  (when the field has its own env key) and, for a write-only secret, the
  <ClearSecretToggle> that arms its removal; an armed secret's input is locked
  and says it will be removed.
-->
<script>
  import Input from '../../ui/Input.svelte';
  import EnvBadge from '../../ui/EnvBadge.svelte';
  import ClearSecretToggle from '../../ui/ClearSecretToggle.svelte';

  let {
    /** Label text */
    label,
    /** Bound: the field value */
    value = $bindable(),
    /** Input type */
    type = 'text',
    /** Placeholder while not armed for removal */
    placeholder = '',
    /** Channel-level lock (the channel's from_env flag) */
    disabled = false,
    /** The field's own env lock; null when the field has no env key (no badge) */
    envLocked = null,
    /** Clearable secret key, e.g. 'telegram.bot_token'; null for plain fields */
    secret = null,
    /** A value for `secret` is stored server-side */
    stored = false,
    /** Bound: removal of `secret` is armed. Only bound when `secret` is set. */
    armed = $bindable(),
    /** Hint shown after the input */
    hint = '',
  } = $props();
</script>

<div class="form-row">
  {#if envLocked === null}
    <span class="form-label">{label}</span>
  {:else}
    <span class="form-label">
      {label}
      <EnvBadge locked={envLocked} />
    </span>
  {/if}
  <Input
    {type}
    bind:value
    placeholder={secret && armed ? 'Will be removed on save' : placeholder}
    disabled={Boolean(disabled || envLocked || (secret && armed))}
    fullWidth
  />
  {#if hint}
    <span class="form-hint">{hint}</span>
  {/if}
  {#if secret}
    <div class="clear-slot">
      <ClearSecretToggle
        {secret}
        {stored}
        {envLocked}
        {disabled}
        bind:armed
      />
    </div>
  {/if}
</div>

<style>
  .form-row {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }

  .form-label {
    width: 140px;
    flex-shrink: 0;
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  .form-hint {
    font-size: 0.6875rem;
    color: var(--text-muted);
    margin-left: 8px;
  }

  /* Own line under the input it belongs to (.form-row wraps), aligned with the
     input rather than with the 140px label column. */
  .clear-slot {
    flex-basis: 100%;
    padding-left: 152px;
  }

  /* No stored secret => the toggle renders nothing => no blank row. */
  .clear-slot:empty {
    display: none;
  }
</style>
