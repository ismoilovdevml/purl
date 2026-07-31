<script>
  import { createEventDispatcher } from 'svelte';
  import { levelStats, serviceStats, hostStats, namespaceStats, podStats, nodeStats, deploymentStats, teamStats } from '../stores/logs.js';
  import { getLevelColor } from '../utils/colors.js';
  import Button from './ui/Button.svelte';
  import Badge from './ui/Badge.svelte';
  import Tooltip from './ui/Tooltip.svelte';
  import Icon from './ui/Icon.svelte';
  import { caretDown, caretRight, caretUp, close, search } from './ui/icons.js';
  import { formatCount } from '../utils/format.js';

  const dispatch = createEventDispatcher();

  export let loading = false;

  let expandedSections = {
    level: true,
    service: true,
    host: true,
    namespace: false,
    pod: false,
    node: false,
    deployment: false,
    team: false,
  };

  let fieldFilter = '';

  function toggleSection(section) {
    expandedSections[section] = !expandedSections[section];
  }

  function toggleAll(expand) {
    expandedSections = {
      level: expand,
      service: expand,
      host: expand,
      namespace: expand,
      pod: expand,
      node: expand,
      deployment: expand,
      team: expand,
    };
  }

  function handleFilter(field, value, exclude = false) {
    const prefix = exclude ? 'NOT ' : '';
    dispatch('filter', { field, value: `${prefix}${field}:${value}` });
  }

  function getPercentage(count, stats) {
    const total = stats.reduce((sum, s) => sum + s.count, 0) || 1;
    return (count / total) * 100;
  }

  // Filter fields by search
  $: filteredLevelStats = $levelStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredServiceStats = $serviceStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredHostStats = $hostStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredNamespaceStats = $namespaceStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredPodStats = $podStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredNodeStats = $nodeStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredDeploymentStats = $deploymentStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));
  $: filteredTeamStats = $teamStats.filter(s => !fieldFilter || s.value.toLowerCase().includes(fieldFilter.toLowerCase()));

  // Check if K8s data exists
  $: hasK8sData = $namespaceStats.length > 0 || $podStats.length > 0 || $nodeStats.length > 0 || $deploymentStats.length > 0 || $teamStats.length > 0;
</script>

<div class="fields-sidebar" aria-busy={loading} aria-live="polite">
  <div class="fields-header">
    <h3>Fields</h3>
    <div class="header-actions">
      <Tooltip content="Expand all">
        <Button icon size="sm" variant="ghost" aria-label="Expand all field sections" on:click={() => toggleAll(true)}>
          <Icon icon={caretDown} size={12} />
        </Button>
      </Tooltip>
      <Tooltip content="Collapse all">
        <Button icon size="sm" variant="ghost" aria-label="Collapse all field sections" on:click={() => toggleAll(false)}>
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

  <!-- Level Section -->
  {#if $levelStats.length > 0}
  <div class="field-section">
    <button
      class="section-header"
      on:click={() => toggleSection('level')}
      aria-expanded={expandedSections.level}
    >
      <Icon icon={caretRight} size={12} class="chevron {expandedSections.level ? 'expanded' : ''}" />
      <span class="section-name">level</span>
      <Badge variant="default" size="sm">{$levelStats.length}</Badge>
    </button>
    {#if expandedSections.level}
      <div class="field-values" role="list">
        {#each filteredLevelStats as item}
          <div class="field-value-row" role="listitem">
            <button
              class="field-value"
              on:click={() => handleFilter('level', item.value)}
              aria-label="Filter by level:{item.value}"
            >
              <span class="value-dot" style="background: {getLevelColor(item.value)}"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $levelStats).toFixed(0)}%</span>
            </button>
            <button
              class="exclude-btn"
              on:click|stopPropagation={() => handleFilter('level', item.value, true)}
              title="Exclude"
              aria-label="Exclude level:{item.value} from results"
            ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Service Section -->
  {#if $serviceStats.length > 0}
  <div class="field-section">
    <button
      class="section-header"
      on:click={() => toggleSection('service')}
      aria-expanded={expandedSections.service}
    >
      <Icon icon={caretRight} size={12} class="chevron {expandedSections.service ? 'expanded' : ''}" />
      <span class="section-name">service</span>
      <Badge variant="default" size="sm">{$serviceStats.length}</Badge>
    </button>
    {#if expandedSections.service}
      <div class="field-values" role="list">
        {#each filteredServiceStats as item}
          <div class="field-value-row" role="listitem">
            <button
              class="field-value"
              on:click={() => handleFilter('service', item.value)}
              aria-label="Filter by service:{item.value}"
            >
              <span class="value-dot" style="background: var(--color-primary)"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $serviceStats).toFixed(0)}%</span>
            </button>
            <button
              class="exclude-btn"
              on:click|stopPropagation={() => handleFilter('service', item.value, true)}
              title="Exclude"
              aria-label="Exclude service:{item.value} from results"
            ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Host Section -->
  {#if $hostStats.length > 0}
  <div class="field-section">
    <button
      class="section-header"
      on:click={() => toggleSection('host')}
      aria-expanded={expandedSections.host}
    >
      <Icon icon={caretRight} size={12} class="chevron {expandedSections.host ? 'expanded' : ''}" />
      <span class="section-name">host</span>
      <Badge variant="default" size="sm">{$hostStats.length}</Badge>
    </button>
    {#if expandedSections.host}
      <div class="field-values" role="list">
        {#each filteredHostStats as item}
          <div class="field-value-row" role="listitem">
            <button
              class="field-value"
              on:click={() => handleFilter('host', item.value)}
              aria-label="Filter by host:{item.value}"
            >
              <span class="value-dot" style="background: var(--color-purple)"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $hostStats).toFixed(0)}%</span>
            </button>
            <button
              class="exclude-btn"
              on:click|stopPropagation={() => handleFilter('host', item.value, true)}
              title="Exclude"
              aria-label="Exclude host:{item.value} from results"
            ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- K8s Section Divider -->
  {#if hasK8sData}
  <div class="section-divider">
    <span>Kubernetes</span>
  </div>
  {/if}

  <!-- Namespace Section -->
  {#if $namespaceStats.length > 0}
  <div class="field-section">
    <button
      class="section-header"
      on:click={() => toggleSection('namespace')}
      aria-expanded={expandedSections.namespace}
    >
      <Icon icon={caretRight} size={12} class="chevron {expandedSections.namespace ? 'expanded' : ''}" />
      <span class="section-name">namespace</span>
      <Badge variant="default" size="sm">{$namespaceStats.length}</Badge>
    </button>
    {#if expandedSections.namespace}
      <div class="field-values" role="list">
        {#each filteredNamespaceStats as item}
          <div class="field-value-row" role="listitem">
            <button
              class="field-value"
              on:click={() => handleFilter('meta.namespace', item.value)}
              aria-label="Filter by meta.namespace:{item.value}"
            >
              <span class="value-dot" style="background: var(--color-orange)"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $namespaceStats).toFixed(0)}%</span>
            </button>
            <button
              class="exclude-btn"
              on:click|stopPropagation={() => handleFilter('meta.namespace', item.value, true)}
              title="Exclude"
              aria-label="Exclude meta.namespace:{item.value} from results"
            ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Pod Section -->
  {#if $podStats.length > 0}
  <div class="field-section">
    <button
      class="section-header"
      on:click={() => toggleSection('pod')}
      aria-expanded={expandedSections.pod}
    >
      <Icon icon={caretRight} size={12} class="chevron {expandedSections.pod ? 'expanded' : ''}" />
      <span class="section-name">pod</span>
      <Badge variant="default" size="sm">{$podStats.length}</Badge>
    </button>
    {#if expandedSections.pod}
      <div class="field-values" role="list">
        {#each filteredPodStats as item}
          <div class="field-value-row" role="listitem">
            <button
              class="field-value"
              on:click={() => handleFilter('meta.pod', item.value)}
              aria-label="Filter by meta.pod:{item.value}"
            >
              <span class="value-dot" style="background: var(--color-success)"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $podStats).toFixed(0)}%</span>
            </button>
            <button
              class="exclude-btn"
              on:click|stopPropagation={() => handleFilter('meta.pod', item.value, true)}
              title="Exclude"
              aria-label="Exclude meta.pod:{item.value} from results"
            ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Node Section -->
  {#if $nodeStats.length > 0}
  <div class="field-section">
    <button
      class="section-header"
      on:click={() => toggleSection('node')}
      aria-expanded={expandedSections.node}
    >
      <Icon icon={caretRight} size={12} class="chevron {expandedSections.node ? 'expanded' : ''}" />
      <span class="section-name">node</span>
      <Badge variant="default" size="sm">{$nodeStats.length}</Badge>
    </button>
    {#if expandedSections.node}
      <div class="field-values" role="list">
        {#each filteredNodeStats as item}
          <div class="field-value-row" role="listitem">
            <button
              class="field-value"
              on:click={() => handleFilter('meta.node', item.value)}
              aria-label="Filter by meta.node:{item.value}"
            >
              <span class="value-dot" style="background: #bc8cff"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $nodeStats).toFixed(0)}%</span>
            </button>
            <button
              class="exclude-btn"
              on:click|stopPropagation={() => handleFilter('meta.node', item.value, true)}
              title="Exclude"
              aria-label="Exclude meta.node:{item.value} from results"
            ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Deployment Section -->
  {#if $deploymentStats.length > 0}
  <div class="field-section">
    <button
      class="section-header"
      on:click={() => toggleSection('deployment')}
      aria-expanded={expandedSections.deployment}
    >
      <Icon icon={caretRight} size={12} class="chevron {expandedSections.deployment ? 'expanded' : ''}" />
      <span class="section-name">deployment</span>
      <Badge variant="default" size="sm">{$deploymentStats.length}</Badge>
    </button>
    {#if expandedSections.deployment}
      <div class="field-values" role="list">
        {#each filteredDeploymentStats as item}
          <div class="field-value-row" role="listitem">
            <button
              class="field-value"
              on:click={() => handleFilter('meta.deployment', item.value)}
              aria-label="Filter by meta.deployment:{item.value}"
            >
              <span class="value-dot" style="background: var(--color-success)"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $deploymentStats).toFixed(0)}%</span>
            </button>
            <button
              class="exclude-btn"
              on:click|stopPropagation={() => handleFilter('meta.deployment', item.value, true)}
              title="Exclude"
              aria-label="Exclude meta.deployment:{item.value} from results"
            ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}

  <!-- Team Section -->
  {#if $teamStats.length > 0}
  <div class="field-section">
    <button
      class="section-header"
      on:click={() => toggleSection('team')}
      aria-expanded={expandedSections.team}
    >
      <Icon icon={caretRight} size={12} class="chevron {expandedSections.team ? 'expanded' : ''}" />
      <span class="section-name">team</span>
      <Badge variant="default" size="sm">{$teamStats.length}</Badge>
    </button>
    {#if expandedSections.team}
      <div class="field-values" role="list">
        {#each filteredTeamStats as item}
          <div class="field-value-row" role="listitem">
            <button
              class="field-value"
              on:click={() => handleFilter('meta.team', item.value)}
              aria-label="Filter by meta.team:{item.value}"
            >
              <span class="value-dot" style="background: var(--color-orange)"></span>
              <span class="value-name">{item.value}</span>
              <span class="value-count">{formatCount(item.count)}</span>
              <span class="value-percent">{getPercentage(item.count, $teamStats).toFixed(0)}%</span>
            </button>
            <button
              class="exclude-btn"
              on:click|stopPropagation={() => handleFilter('meta.team', item.value, true)}
              title="Exclude"
              aria-label="Exclude meta.team:{item.value} from results"
            ><Icon icon={close} size={10} strokeWidth={3.5} /></button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
  {/if}
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
