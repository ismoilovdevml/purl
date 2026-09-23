<!--
  StatTile
  Small bordered tile with a big number over an uppercase caption, as used in
  the stats rows of the Agents and Sources settings pages. The value can be
  tinted by a tone; pass children instead of a value to put something else in
  the tile (e.g. a loading spinner, or a list under the caption). With
  children, a label (if given) is rendered above them.

  Usage:
  <StatTile value={12} label="Online" tone={online > 0 ? 'success' : null} />
  <StatTile><LoadingSpinner size="sm" /></StatTile>
  <StatTile label="Top Actions" wide>...list...</StatTile>
-->
<script>
  let {
    /** Number (or preformatted string) shown large */
    value = '',
    /** Caption under the value */
    label = '',
    /** Tint for the value: 'success' | 'warning' | 'danger' | null */
    tone = null,
    /** Stretch to fill the row (min 220px) — for a tile holding a list */
    wide = false,
    /** Optional content replacing the value (label, if set, stays on top) */
    children,
  } = $props();
</script>

<div
  class="stat-card"
  class:stat-success={tone === 'success'}
  class:stat-warning={tone === 'warning'}
  class:stat-danger={tone === 'danger'}
  class:stat-breakdown={wide}
>
  {#if children}
    {#if label}
      <span class="stat-label">{label}</span>
    {/if}
    {@render children()}
  {:else}
    <span class="stat-value">{value}</span>
    <span class="stat-label">{label}</span>
  {/if}
</div>

<style>
  .stat-card {
    background: var(--bg-secondary);
    border: 1px solid var(--border-muted);
    border-radius: 8px;
    padding: 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    min-width: 120px;
  }

  .stat-card.stat-breakdown {
    flex: 1;
    min-width: 220px;
  }

  .stat-card.stat-success .stat-value {
    color: #3fb950;
  }

  .stat-card.stat-warning .stat-value {
    color: #d29922;
  }

  .stat-card.stat-danger .stat-value {
    color: #f85149;
  }

  .stat-value {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--text-bright);
    line-height: 1;
  }

  .stat-label {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
</style>
