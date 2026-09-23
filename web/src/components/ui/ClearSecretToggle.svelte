<!--
  ClearSecretToggle Component
  Arms the removal of ONE stored write-only secret. It does not delete
  anything itself: the panel's own Save (behind <ClearSecretConfirm>) sends
  the `clear_<field>` instruction, so an accidental tick costs nothing until
  the user confirms a save.

  Renders NOTHING when no value is stored — there is nothing to remove, and an
  inert "remove" control next to an empty field only invites a support ticket.

  Usage:
  <ClearSecretToggle
    secret="telegram.bot_token"
    stored={storedSecrets['telegram.bot_token']}
    envLocked={isEnvLocked(envKeys, 'telegram.bot_token')}
    bind:armed={clearing['telegram.bot_token']}
  />
-->
<script>
  import EnvBadge from './EnvBadge.svelte';
  import { secretLabel } from '../../utils/clearSecret.js';

  let {
    /** Section-relative key of the secret, e.g. 'telegram.bot_token'. */
    secret = '',
    /** Is a value actually stored? From the API's *_set / has_credentials flag. */
    stored = false,
    /**
     * The environment owns this key. The server answers 409 to any attempt to
     * change OR clear it, so the control is disabled and carries an <EnvBadge>
     * saying why — never disabled without a reason.
     */
    envLocked = false,
    /** Panel-level lock (coarse from_env flag, save in flight, ...). */
    disabled = false,
    /** Bound: the user armed the removal. The panel's Save performs it. */
    armed = $bindable(false),
  } = $props();

  const label = $derived(secretLabel(secret));
  const locked = $derived(disabled || envLocked);

  /*
   * A control the user can no longer see or reach must not leave a live
   * instruction behind: a field that becomes env-locked, or whose stored value
   * disappeared under us on a refetch, would otherwise smuggle a clear_* into
   * the next save of an unrelated field.
   *
   * $effect.pre (not $effect) so the reset lands in the same flush as the
   * change that caused it, the way the old `$:` statement did — a plain
   * $effect would let one frame render with the stale armed state.
   *
   * Only writes when there is something to reset. `armed` is bound into
   * legacy-mode panels (`bind:armed={clearing[key]}`), where every write —
   * even false over false — invalidates the parent's whole object and
   * re-runs this effect: an unconditional write froze the tab in an endless
   * update loop for any toggle with nothing stored (#85).
   */
  $effect.pre(() => {
    if (armed && (locked || !stored)) armed = false;
  });
</script>

{#if stored}
  <div class="clear-secret" class:armed data-clear-secret={secret}>
    <label class="clear-secret-label">
      <input
        type="checkbox"
        bind:checked={armed}
        disabled={locked}
        aria-label="Remove stored {label}"
      />
      <span>Remove stored value</span>
    </label>

    <EnvBadge locked={envLocked} />

    {#if armed}
      <span class="clear-secret-warning" role="status">
        {label} will be deleted when you save. This cannot be undone.
      </span>
    {/if}
  </div>
{/if}

<style>
  .clear-secret {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: var(--space-2);
    font-size: var(--text-xs);
    color: var(--text-muted);
  }

  .clear-secret-label {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    cursor: pointer;
  }

  .clear-secret-label:has(input:disabled) {
    cursor: not-allowed;
    opacity: 0.5;
  }

  .clear-secret input {
    accent-color: var(--color-error);
    cursor: inherit;
    margin: 0;
  }

  .clear-secret.armed {
    color: var(--color-error);
  }

  .clear-secret-warning {
    color: var(--color-error);
  }
</style>
