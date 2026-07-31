<!--
  Icon Component
  Renders a glyph imported from ./icons.js.

  Every icon is drawn on the same normalised 24x24 grid with
  `stroke="currentColor"`, `fill="none"` and `stroke-width: 2`, so icons inherit
  colour from their container and line up with each other at any size. A handful
  of glyphs opt out (solid marks, brand logos) and carry their own viewBox/fill.

  Usage:
  import Icon from '../ui/Icon.svelte';
  import { close, lock, refresh, chevronRight } from '../ui/icons.js';

  <Icon icon={close} size={16} />
  <Icon icon={lock} size={12} label="Locked" />
  <Icon icon={refresh} size={14} spin={loading} />
  <Icon icon={chevronRight} size={12} class="chevron {open ? 'expanded' : ''}" />

  The `icon` prop takes the imported glyph itself, never a name string. That is
  what keeps icons.js tree-shakeable: a string registry would need
  `import * as ICONS`, which forces Rollup to retain every glyph in the eager
  chunk. Dynamic choices build a local map of imported glyphs instead:

      import { check, xCircle } from '../ui/icons.js';
      const STATUS_ICON = { ok: check, failed: xCircle };
      <Icon icon={STATUS_ICON[status]} size={14} />

  Accessibility: without `label` the icon is decorative (aria-hidden). Pass
  `label` only when the icon carries meaning no adjacent text already conveys —
  an icon-only button needs one, an icon beside its own label does not.

  Note: shapes are rendered as real SVG elements, never via {@html}, so glyph
  data can never become markup.
-->
<script>
  let {
    /** Glyph imported from ./icons.js. */
    icon,
    /** Rendered width/height in px. */
    size = 16,
    /** Accessible name. When omitted the icon is hidden from assistive tech. */
    label = null,
    /** Override the icon's stroke width (raise it below ~16px to keep weight). */
    strokeWidth = null,
    /** Apply the shared spin animation. */
    spin = false,
    /** Override the inherited colour (accepts any CSS colour). */
    color = null,
    class: className = '',
  } = $props();

  const def = $derived(Array.isArray(icon) ? { shapes: icon } : (icon ?? null));
  const shapes = $derived(
    (def?.shapes ?? []).map((s) => (typeof s === 'string' ? ['path', { d: s }] : s))
  );

  $effect(() => {
    if (import.meta.env.DEV && !def) {
      console.warn('[Icon] missing or unknown `icon` prop — did you import the glyph from icons.js?');
    }
  });
</script>

{#if def}
  <svg
    class={className}
    class:icon-spin={spin}
    width={size}
    height={size}
    viewBox={def.viewBox || '0 0 24 24'}
    fill={def.fill ? 'currentColor' : 'none'}
    stroke={def.fill ? 'none' : 'currentColor'}
    stroke-width={def.fill ? null : (strokeWidth ?? def.strokeWidth ?? 2)}
    stroke-linecap="round"
    stroke-linejoin="round"
    style={color ? `color: ${color}` : null}
    role={label ? 'img' : null}
    aria-label={label || null}
    aria-hidden={label ? null : 'true'}
    focusable="false"
  >
    {#each shapes as [tag, attrs]}
      {#if tag === 'circle'}
        <circle {...attrs} />
      {:else if tag === 'rect'}
        <rect {...attrs} />
      {:else if tag === 'line'}
        <line {...attrs} />
      {:else if tag === 'ellipse'}
        <ellipse {...attrs} />
      {:else if tag === 'polyline'}
        <polyline {...attrs} />
      {:else if tag === 'polygon'}
        <polygon {...attrs} />
      {:else}
        <path {...attrs} />
      {/if}
    {/each}
  </svg>
{/if}

<style>
  svg {
    flex-shrink: 0;
  }

  /* @keyframes spin lives in src/styles/animations.css (declared once). */
  .icon-spin {
    animation: spin 1s linear infinite;
  }
</style>
