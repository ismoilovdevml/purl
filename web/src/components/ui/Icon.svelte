<!--
  Icon Component
  Renders a glyph from the shared registry in ./icons.js.

  Every icon is drawn on the same normalised 24x24 grid with
  `stroke="currentColor"`, `fill="none"` and `stroke-width: 2`, so icons inherit
  colour from their container and line up with each other at any size.

  Usage:
  <Icon name="close" size={16} />
  <Icon name="lock" size={12} label="Locked" />
  <Icon name="refresh" size={14} spin={loading} />
  <Icon name="chevron-right" size={12} class="chevron {open ? 'expanded' : ''}" />

  Accessibility: without `label` the icon is decorative (aria-hidden). Pass
  `label` only when the icon carries meaning no adjacent text already conveys.

  Note: shapes are rendered as real SVG elements, never via {@html}, so an
  unexpected `name` can only ever render nothing.
-->
<script>
  import * as ICONS from './icons.js';

  /** Registry name, kebab-case or camelCase (e.g. 'chevron-down'). */
  export let name;
  /** Rendered width/height in px. */
  export let size = 16;
  /** Accessible name. When omitted the icon is hidden from assistive tech. */
  export let label = null;
  /** Override the icon's stroke width. */
  export let strokeWidth = null;
  /** Apply the shared spin animation. */
  export let spin = false;
  /** Override the inherited colour (accepts any CSS colour). */
  export let color = null;

  let className = '';
  export { className as class };

  const toKey = (n) => String(n).replace(/-([a-z])/g, (_, c) => c.toUpperCase());

  $: key = toKey(name);
  // Module namespace objects have a null prototype, so this cannot be tricked
  // into resolving inherited properties.
  $: def = Object.prototype.hasOwnProperty.call(ICONS, key) ? ICONS[key] : null;
  $: icon = Array.isArray(def) ? { shapes: def } : def;
  $: shapes = (icon?.shapes ?? []).map((s) => (typeof s === 'string' ? ['path', { d: s }] : s));

  $: if (name && !icon) console.warn(`[Icon] unknown icon name: "${name}"`);
</script>

{#if icon}
  <svg
    class={className}
    class:icon-spin={spin}
    width={size}
    height={size}
    viewBox={icon.viewBox || '0 0 24 24'}
    fill={icon.fill ? 'currentColor' : 'none'}
    stroke={icon.fill ? 'none' : 'currentColor'}
    stroke-width={icon.fill ? null : (strokeWidth ?? icon.strokeWidth ?? 2)}
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
