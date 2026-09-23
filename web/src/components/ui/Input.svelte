<!--
  Input Component
  Flexible input with label, validation, and icons

  Usage:
  <Input bind:value={email} label="Email" type="email" placeholder="Enter email" />
  <Input bind:value={search} placeholder="Search..." onenter={({ value }) => run(value)}>
    {#snippet icon()}<Icon icon={search} size={16} />{/snippet}
  </Input>
-->
<script>
  import EnvBadge from './EnvBadge.svelte';

  let {
    /** Input type */
    type = 'text',
    /**
     * Input value. Deliberately no fallback: a runes $bindable with a default
     * throws when a parent binds `undefined` (e.g. a not-yet-loaded form field).
     */
    value = $bindable(),
    /** Label text */
    label = '',
    /** Placeholder text */
    placeholder = '',
    /** Error message */
    error = '',
    /** Helper text */
    helper = '',
    /** Disabled state */
    disabled = false,
    /** Required field */
    required = false,
    /** Input size: sm, md, lg */
    size = 'md',
    /** Full width */
    fullWidth = false,
    /** Input name */
    name = '',
    /** Autocomplete */
    autocomplete = 'off',
    /** Min value (for number) */
    min = undefined,
    /** Max value (for number) */
    max = undefined,
    /** Step (for number) */
    step = undefined,
    /** Readonly */
    readonly = false,
    /** Input id (auto-generated if not provided) */
    id = '',
    /**
     * Field is pinned by a server environment variable.
     *
     * Forces the control disabled (the server answers 409 for such a change) AND
     * shows an <EnvBadge> next to the label, so the field is never disabled
     * without a visible reason. Independent of `disabled`: a field can be locked
     * by ENV and disabled for an unrelated reason at the same time.
     */
    envLocked = false,
    /** ({ value }) on every keystroke, after `value` is updated */
    oninput,
    /** ({ value }) on commit (blur / Enter), like the native change event */
    onchange,
    /** (FocusEvent) */
    onfocus,
    /** (FocusEvent) */
    onblur,
    /** (KeyboardEvent) */
    onkeydown,
    /** ({ value }) when Enter is pressed */
    onenter,
    /** Leading icon snippet */
    icon,
    /** Trailing suffix snippet */
    suffix,
  } = $props();

  const isDisabled = $derived(disabled || envLocked);

  // Generate unique id for label-input association (fixed at creation, as before)
  // svelte-ignore state_referenced_locally
  const uniqueId = id || `input-${Math.random().toString(36).slice(2, 9)}`;

  function handleInput(event) {
    value = event.target.value;
    oninput?.({ value });
  }

  function handleChange(event) {
    onchange?.({ value: event.target.value });
  }

  function handleFocus(event) {
    onfocus?.(event);
  }

  function handleBlur(event) {
    onblur?.(event);
  }

  function handleKeydown(event) {
    onkeydown?.(event);
    if (event.key === 'Enter') {
      onenter?.({ value: value ?? '' });
    }
  }
</script>

<div class="input-wrapper" class:full-width={fullWidth}>
  {#if label || envLocked}
    <label class="input-label" class:required for={uniqueId}>
      {label}
      <EnvBadge locked={envLocked} />
    </label>
  {/if}

  <div class="input-container focus-shell" class:has-error={error} class:disabled={isDisabled} class:size-sm={size === 'sm'} class:size-lg={size === 'lg'}>
    {#if icon}
      <span class="input-icon">
        {@render icon()}
      </span>
    {/if}

    {#if type === 'textarea'}
      <textarea
        id={uniqueId}
        {name}
        {placeholder}
        disabled={isDisabled}
        {readonly}
        {required}
        class="input-field"
        bind:value
        oninput={handleInput}
        onchange={handleChange}
        onfocus={handleFocus}
        onblur={handleBlur}
        onkeydown={handleKeydown}
      ></textarea>
    {:else}
      <input
        id={uniqueId}
        {type}
        {name}
        {placeholder}
        disabled={isDisabled}
        {readonly}
        {required}
        {autocomplete}
        {min}
        {max}
        {step}
        class="input-field"
        bind:value
        oninput={handleInput}
        onchange={handleChange}
        onfocus={handleFocus}
        onblur={handleBlur}
        onkeydown={handleKeydown}
      />
    {/if}

    {#if suffix}
      <span class="input-suffix">
        {@render suffix()}
      </span>
    {/if}
  </div>

  {#if error}
    <span class="input-error">{error}</span>
  {:else if helper}
    <span class="input-helper">{helper}</span>
  {/if}
</div>

<style>
  .input-wrapper {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }

  .input-wrapper.full-width {
    width: 100%;
  }

  .input-label {
    font-size: var(--text-sm);
    font-weight: 500;
    color: var(--text-secondary);
  }

  .input-label.required::after {
    content: ' *';
    color: var(--color-error);
  }

  .input-container {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    padding: 0 var(--space-3);
    transition: var(--transition-fast);
  }

  .input-container:focus-within {
    border-color: var(--color-primary);
    box-shadow: 0 0 0 2px var(--color-primary-bg);
  }

  .input-container.has-error {
    border-color: var(--color-error);
  }

  .input-container.has-error:focus-within {
    box-shadow: 0 0 0 2px var(--color-error-bg);
  }

  /* The shell's focus ring (focus.css) follows the error state. */
  .input-container.has-error:has(> .input-field:focus-visible) {
    outline-color: var(--color-error);
  }

  .input-container.disabled {
    opacity: 0.5;
    cursor: not-allowed;
    background: var(--bg-secondary);
  }

  /* Sizes */
  .input-container {
    height: 36px;
  }

  .input-container.size-sm {
    height: 28px;
    padding: 0 var(--space-2);
  }

  .input-container.size-lg {
    height: 44px;
  }

  .input-field {
    flex: 1;
    min-width: 0;
    background: transparent;
    border: none;
    /* No `outline: none` here: .focus-shell (styles/focus.css) moves the
       keyboard ring from this field onto .input-container, so there is
       exactly one ring, on the visible border. */
    font-size: var(--text-base);
    color: var(--text-primary);
    font-family: inherit;
  }

  .input-field::placeholder {
    color: var(--text-muted);
  }

  .input-field:disabled {
    cursor: not-allowed;
  }

  textarea.input-field {
    resize: vertical;
    min-height: 80px;
    padding: var(--space-2) 0;
  }

  .input-container:has(textarea) {
    height: auto;
    align-items: flex-start;
  }

  .input-icon {
    display: flex;
    align-items: center;
    color: var(--text-muted);
    flex-shrink: 0;
  }

  .input-icon :global(svg) {
    width: 16px;
    height: 16px;
  }

  .input-suffix {
    display: flex;
    align-items: center;
    color: var(--text-muted);
    flex-shrink: 0;
  }

  .input-error {
    font-size: var(--text-xs);
    color: var(--color-error);
  }

  .input-helper {
    font-size: var(--text-xs);
    color: var(--text-muted);
  }

  /* Number input arrows */
  .input-field[type='number']::-webkit-outer-spin-button,
  .input-field[type='number']::-webkit-inner-spin-button {
    -webkit-appearance: none;
    margin: 0;
  }

  .input-field[type='number'] {
    -moz-appearance: textfield;
  }
</style>
