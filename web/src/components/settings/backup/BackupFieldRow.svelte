<!--
  BackupFieldRow
  One labelled input row in the backup schedule / S3 panels: a fixed-width
  label carrying the ENV badge, and a plain input. BackupConfig decides
  whether the field is locked.
-->
<script>
  import EnvBadge from '../../ui/EnvBadge.svelte';

  let {
    /** Input id, also the label's for= */
    id,
    /** Visible label text */
    label,
    /** The field is pinned by an environment variable (shows the badge) */
    locked = false,
    /** Input type: 'text' | 'number' | 'password' */
    type = 'text',
    /** Field value */
    value = $bindable(),
    /** Wider input (bucket, endpoint, secret) */
    wide = false,
    /** Optional input attributes, passed straight through */
    placeholder,
    min,
    max,
    disabled = false,
  } = $props();
</script>

<div class="field-row">
  <label class="field-label" for={id}>
    {label}
    <EnvBadge {locked} />
  </label>
  <input
    {id}
    {type}
    class="field-input"
    class:field-input-wide={wide}
    bind:value
    {min}
    {max}
    {placeholder}
    {disabled}
  />
</div>

<style>
  .field-row {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .field-label {
    font-size: 0.85rem;
    color: var(--text-secondary);
    min-width: 260px;
    flex-shrink: 0;
  }

  .field-input {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: 6px;
    color: var(--text-primary);
    padding: 6px 10px;
    font-size: 0.85rem;
    width: 140px;
  }

  .field-input-wide {
    width: 280px;
  }

  .field-input:focus {
    border-color: var(--color-primary);
    box-shadow: 0 0 0 2px rgba(88, 166, 255, 0.15);
  }

  .field-input:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
</style>
