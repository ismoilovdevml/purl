<script>
  import { levelStats, serviceStats, hostStats, namespaceStats, podStats, nodeStats, deploymentStats, teamStats } from '../stores/logs.js';
  import { getLevelColor } from '../utils/colors.js';
  import Button from './ui/Button.svelte';
  import Badge from './ui/Badge.svelte';
  import Tooltip from './ui/Tooltip.svelte';
  import Icon from './ui/Icon.svelte';
  import { caretDown, caretRight, caretUp, close, search } from './ui/icons.js';
  import { formatCount } from '../utils/format.js';

  /** @type {{ loading?: boolean, onfilter?: (e: { field: string, value: string }) => void }} */
  let { loading = false, onfilter } = $props();

  /*
   * One entry per field section, in render order. `key` names the section,
   * `field` is what goes into the query, `color` paints the value dot (a
   * function for level, whose colour depends on the value), and `k8s` marks
   * the sections that sit under the "Kubernetes" divider.
   */
  const SECTIONS = [
    { key: 'level', field: 'level', store: levelStats, color: (v) => getLevelColor(v), open: true },
    { key: 'service', field: 'service', store: serviceStats, color: 'var(--color-primary)', open: true },
    { key: 'host', field: 'host', store: hostStats, color: 'var(--color-purple)', open: true },
    { key: 'namespace', field: 'meta.namespace', store: namespaceStats, color: 'var(--color-orange)', k8s: true },
    { key: 'pod', field: 'meta.pod', store: podStats, color: 'var(--color-success)', k8s: true },
    { key: 'node', field: 'meta.node', store: nodeStats, color: '#bc8cff', k8s: true },
    { key: 'deployment', field: 'meta.deployment', store: deploymentStats, color: 'var(--color-success)', k8s: true },
    { key: 'team', field: 'meta.team', store: teamStats, color: 'var(--color-orange)', k8s: true },
  ];

  let expandedSections = $state(Object.fromEntries(SECTIONS.map((s) => [s.key, !!s.open])));

  let fieldFilter = $state('');

  // `$store` only works on top-level identifiers, so each store is read here
  // once and indexed by section key for the data-driven template below.
  const statsByKey = $derived({
    level: $levelStats,
    service: $serviceStats,
    host: $hostStats,
    namespace: $namespaceStats,
    pod: $podStats,
    node: $nodeStats,
    deployment: $deploymentStats,
    team: $teamStats,
  });

  const hasK8sData = $derived(SECTIONS.some((s) => s.k8s && statsByKey[s.key].length > 0));

  function toggleSection(section) {
    expandedSections[section] = !expandedSections[section];
  }

  function toggleAll(expand) {
    for (const s of SECTIONS) expandedSections[s.key] = expand;
  }

  function handleFilter(field, value, exclude = false) {
    const prefix = exclude ? 'NOT ' : '';
    onfilter?.({ field, value: `${prefix}${field}:${value}` });
  }

  function getPercentage(count, stats) {
    const total = stats.reduce((sum, s) => sum + s.count, 0) || 1;
    return (count / total) * 100;
  }

  function matchesFilter(item) {
    return !fieldFilter || item.value.toLowerCase().includes(fieldFilter.toLowerCase());
  }

  function dotColor(section, value) {
    return typeof section.color === 'function' ? section.color(value) : section.color;
  }
</script>

<div class="fields-sidebar" aria-busy={loading} aria-live="polite">
  <div class="fields-header">
    <h3>Fields</h3>
    <div class="header-actions">
      <Tooltip content="Expand all">
        <Button icon size="sm" variant="ghost" aria-label="Expand all field sections" onclick={() => toggleAll(true)}>
          <Icon icon={caretDown} size={12} />
        </Button>
      </Tooltip>
      <Tooltip content="Collapse all">
        <Button icon size="sm" variant="ghost" aria-label="Collapse all field sections" onclick={() => toggleAll(false)}>
          <Icon icon={caretUp} size={12} />
        </Button>
      </Tooltip>
    </div>
  </div>

  <div class="field-search">
    <Icon icon={search} size={12} strokeWidth={3} class="search-icon" />
    <input type="text" bind:value={fieldFilter} placeholder="Filter fields..." aria-label="Filter fields" />
  </div>

  {#if loading}
    <div class="field-skeleton" aria-hidden="true">
      {#each [80, 60, 90, 45, 70] as width}
        <div class="skeleton-bar" style="width: {width}%"></div>
      {/each}
    </div>
  {/if}

  {#each SECTIONS as section (section.key)}
    {@const stats = statsByKey[section.key]}
    {#if section.key === 'namespace' && hasK8sData}
      <div class="section-divider">
        <span>Kubernetes</span>
      </div>
    {/if}
    {#if stats.length > 0}
      <div class="field-section">
        <button
          class="section-header"
          onclick={() => toggleSection(section.key)}
          aria-expanded={expandedSections[section.key]}
        >
          <Icon icon={caretRight} size={12} class="chevron {expandedSections[section.key] ? 'expanded' : ''}" />
          <span class="section-name">{section.key}</span>
          <Badge variant="default" size="sm">{stats.length}</Badge>
        </button>
        {#if expandedSections[section.key]}
          <div class="field-values" role="list">
            {#each stats.filter(matchesFilter) as item}
              <div class="field-value-row" role="listitem">
                <button
                  class="field-value"
                  onclick={() => handleFilter(section.field, item.value)}
                  aria-label="Filter by {section.field}:{item.value}"
                >
                  <span class="value-dot" style="background: {dotColor(section, item.value)}"></span>
                  <span class="value-name">{item.value}</span>
                  <span class="value-count">{formatCount(item.count)}</span>
                  <span class="value-percent">{getPercentage(item.count, stats).toFixed(0)}%</span>
                </button>
                <button
                  class="exclude-btn"
                  onclick={(e) => { e.stopPropagation(); handleFilter(section.field, item.value, true); }}
                  title="Exclude"
                  aria-label="Exclude {section.field}:{item.value} from results"
                ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
              </div>
            {/each}
          </div>
        {/if}
      </div>
    {/if}
  {/each}
</div>

<style>
  .fields-sidebar { margin-bottom: 16px; }
  .fields-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
  .fields-header h3 { font-size: 12px; font-weight: 600; text-transform: uppercase; color: var(--text-secondary); letter-spacing: 0.5px; margin: 0; }
  .header-actions { display: flex; gap: 4px; }

  .field-search { display: flex; align-items: center; gap: 8px; padding: 6px 8px; background: var(--bg-primary); border: 1px solid var(--border-color); border-radius: 6px; margin-bottom: 12px; }
  .field-search :global(.search-icon) { color: var(--text-muted); flex-shrink: 0; }
  .field-search input { flex: 1; background: none; border: none; color: var(--text-primary); font-size: 12px; }
  .field-search input::placeholder { color: var(--text-muted); }

  .section-divider { display: flex; align-items: center; gap: 8px; margin: 12px 0 8px 0; color: var(--text-muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }
  .section-divider::before, .section-divider::after { content: ''; flex: 1; height: 1px; background: var(--border-color); }

  .field-section { margin-bottom: 4px; }
  .section-header { display: flex; align-items: center; gap: 8px; width: 100%; padding: 6px 8px; background: none; border: none; color: var(--text-primary); cursor: pointer; border-radius: 6px; font-size: 13px; font-weight: 500; }
  .section-header:hover { background: var(--bg-tertiary); }
  .section-name { flex: 1; text-align: left; }
  /* :global — the chevron svg is rendered by <Icon>, so the scoping class
     never lands on it; the class name itself is still supplied here. */
  .section-header :global(.chevron) { transition: transform 0.2s; flex-shrink: 0; }
  .section-header :global(.chevron.expanded) { transform: rotate(90deg); }

  .field-values { padding-left: 12px; }
  .field-value-row { display: flex; align-items: center; gap: 2px; }
  .field-value { display: flex; align-items: center; gap: 6px; flex: 1; padding: 4px 6px; background: none; border: none; color: var(--text-primary); cursor: pointer; border-radius: 4px; font-size: 12px; text-align: left; }
  .field-value:hover { background: var(--bg-tertiary); }

  .exclude-btn { display: flex; align-items: center; justify-content: center; padding: 2px 6px; background: none; border: none; color: var(--text-muted); cursor: pointer; border-radius: 4px; opacity: 0; }
  .field-value-row:hover .exclude-btn { opacity: 1; }
  /* Keyboard users never trigger :hover — keep the button reachable. */
  .exclude-btn:focus-visible { opacity: 1; }
  .exclude-btn:hover { color: var(--color-error); background: rgba(248, 81, 73, 0.1); }

  .value-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
  .value-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 40px; }
  .value-count { color: var(--text-secondary); font-size: 11px; font-family: var(--font-mono); min-width: 32px; text-align: right; }
  .value-percent { color: var(--text-muted); font-size: 11px; min-width: 28px; text-align: right; }

  .field-skeleton { padding: 8px 0; display: flex; flex-direction: column; gap: 8px; }

  .skeleton-bar {
    height: 20px;
    border-radius: 4px;
    background: linear-gradient(
      90deg,
      var(--bg-tertiary) 25%,
      var(--bg-secondary) 50%,
      var(--bg-tertiary) 75%
    );
    background-size: 200% 100%;
    animation: skeleton-shimmer 1.5s infinite;
  }

  @keyframes skeleton-shimmer {
    0% { background-position: 200% 0; }
    100% { background-position: -200% 0; }
  }
</style>
