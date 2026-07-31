<!--
  EnvBadge Component
  Marks a settings field the server environment owns (and that is therefore
  disabled). Renders NOTHING when the field is not pinned, so callers can drop
  it next to any label unconditionally.

  Usage:
  <EnvBadge locked={isEnvLocked(fromEnvKeys, 'telegram.chat_id')} />
  <EnvBadge locked={schedule.from_env} label="Configured via ENV" />
-->
<script>
  import { ENV_LOCK_REASON } from '../../utils/envLock.js';

  /** Whether the field is pinned by an environment variable */
  export let locked = false;

  /** Badge text */
  export let label = 'ENV';

  /** Tooltip explaining WHY the field is disabled */
  export let reason = ENV_LOCK_REASON;
</script>

{#if locked}
  <span
    class="env-badge"
    data-env-locked="true"
    role="note"
    title={reason}
    aria-label="{label} — {reason}"
  >{label}</span>
{/if}

<style>
  .env-badge {
    display: inline-block;
    vertical-align: middle;
    margin-left: var(--space-2);
    font-size: 10px;
    font-weight: 700;
    line-height: 1.6;
    letter-spacing: 0.03em;
    background: var(--color-warning-bg);
    color: var(--color-warning);
    /* Same values the four hand-rolled copies of this badge used. */
    border: 1px solid rgba(210, 153, 34, 0.3);
    border-radius: var(--radius-sm);
    padding: 1px 5px;
    cursor: help;
    white-space: nowrap;
  }
</style>
