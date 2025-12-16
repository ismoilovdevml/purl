<script>
  import { onMount, onDestroy } from 'svelte';
  import { writable } from 'svelte/store';
  import { detectServiceType, serviceTypes } from '../lib/serviceIcons.js';
  import { query, searchLogs } from '../stores/logs.js';
  import ServiceMetricsChart from './ServiceMetricsChart.svelte';
  import ServiceLatencyChart from './ServiceLatencyChart.svelte';

  // Stores
  export const services = writable([]);
  export const dependencies = writable({ nodes: [], edges: [] });
  export const loading = writable(false);
  export const selectedService = writable(null);

  let svgElement;
  let containerElement;
  let simulation = null;
  let width = 800;
  let height = 600;
  let transform = { x: 0, y: 0, k: 1 };

  let serviceDetails = null;
  let detailsLoading = false;
  let hoveredNode = null;
  let tooltipPosition = { x: 0, y: 0 };
  let searchQuery = '';
  let showFilters = false;
  let metricsData = [];
  let latencyData = { percentiles: {}, timeseries: [] };
  let isDragging = false;
  let dragStartPos = { x: 0, y: 0 };

  // Graph data
  let nodes = [];
  let links = [];

  // Filters
  let filters = {
    types: {},
    health: { healthy: true, degraded: true, critical: true, unknown: true }
  };

  serviceTypes.forEach(t => { filters.types[t.type] = true; });

  const API_BASE = '/api';

  // Fetch services
  async function fetchServices(range = '1h') {
    loading.set(true);
    try {
      const response = await fetch(`${API_BASE}/services?range=${range}`);
      if (response.ok) {
        const data = await response.json();
        services.set(data.services || []);
      }
    } catch (err) {
      console.error('Failed to fetch services:', err);
    } finally {
      loading.set(false);
    }
  }

  // Fetch dependencies
  async function fetchDependencies(range = '1h') {
    loading.set(true);
    try {
      const response = await fetch(`${API_BASE}/services/dependencies?range=${range}`);
      if (response.ok) {
        const data = await response.json();
        dependencies.set(data);
        processGraphData(data);
      }
    } catch (err) {
      console.error('Failed to fetch dependencies:', err);
    } finally {
      loading.set(false);
    }
  }

  // Fetch service details
  async function fetchServiceDetails(name) {
    detailsLoading = true;
    metricsData = [];
    latencyData = { percentiles: {}, timeseries: [] };

    try {
      const [detailsRes, metricsRes, latencyRes] = await Promise.all([
        fetch(`${API_BASE}/services/${encodeURIComponent(name)}?range=${selectedRange}`),
        fetch(`${API_BASE}/services/${encodeURIComponent(name)}/metrics?range=${selectedRange}`),
        fetch(`${API_BASE}/services/${encodeURIComponent(name)}/latency?range=${selectedRange}`)
      ]);

      if (detailsRes.ok) serviceDetails = await detailsRes.json();
      if (metricsRes.ok) {
        const data = await metricsRes.json();
        metricsData = data.data || [];
      }
      if (latencyRes.ok) latencyData = await latencyRes.json();
    } catch (err) {
      console.error('Failed to fetch service details:', err);
    } finally {
      detailsLoading = false;
    }
  }

  // Get health status
  function getHealthStatus(errorCount, logCount) {
    if (!logCount || logCount === 0) return { status: 'unknown', color: '#6b7280' };
    const errorRate = (errorCount / logCount) * 100;
    if (errorRate >= 10) return { status: 'critical', color: '#ef4444' };
    if (errorRate >= 5) return { status: 'degraded', color: '#f59e0b' };
    return { status: 'healthy', color: '#10b981' };
  }

  // Process graph data for D3
  function processGraphData(data) {
    const nodeMap = new Map();

    nodes = (data.nodes || []).map(n => {
      const health = getHealthStatus(n.data.error_count, n.data.log_count);
      const typeInfo = detectServiceType(n.data.id);
      const node = {
        id: n.data.id,
        label: n.data.label || n.data.id,
        logCount: n.data.log_count || 0,
        errorCount: n.data.error_count || 0,
        health: health.status,
        healthColor: health.color,
        type: typeInfo.type,
        typeLabel: typeInfo.label,
        color: typeInfo.color,
        textColor: typeInfo.textColor,
        abbrev: typeInfo.abbrev,
        x: width / 2 + (Math.random() - 0.5) * 200,
        y: height / 2 + (Math.random() - 0.5) * 200,
      };
      nodeMap.set(node.id, node);
      return node;
    });

    links = (data.edges || []).map(e => ({
      id: e.data.id,
      source: nodeMap.get(e.data.source) || e.data.source,
      target: nodeMap.get(e.data.target) || e.data.target,
      callCount: e.data.call_count || 0,
      errorCount: e.data.error_count || 0,
      hasErrors: e.data.error_count > 0,
    }));

    initSimulation();
  }

  // Initialize D3 force simulation
  async function initSimulation() {
    if (!svgElement || nodes.length === 0) return;

    const d3 = await import('d3');

    // Stop existing simulation
    if (simulation) simulation.stop();

    // Calculate optimal link distance based on number of nodes
    const nodeCount = nodes.length;
    const linkDistance = Math.max(200, 400 / Math.sqrt(nodeCount));
    const chargeStrength = -2500 / Math.sqrt(nodeCount);

    // Create force simulation with very strong repulsion to prevent clustering
    simulation = d3.forceSimulation(nodes)
      .force('link', d3.forceLink(links).id(d => d.id).distance(linkDistance).strength(0.2))
      .force('charge', d3.forceManyBody().strength(chargeStrength).distanceMin(100).distanceMax(1000))
      .force('center', d3.forceCenter(width / 2, height / 2).strength(0.05))
      .force('collision', d3.forceCollide().radius(80).strength(1).iterations(3))
      .force('x', d3.forceX(width / 2).strength(0.01))
      .force('y', d3.forceY(height / 2).strength(0.01))
      .alphaDecay(0.02)
      .alphaMin(0.001)
      .velocityDecay(0.3)
      .on('tick', () => {
        nodes = [...nodes];
        links = [...links];
      });

    // Setup zoom
    const svg = d3.select(svgElement);
    const zoom = d3.zoom()
      .scaleExtent([0.2, 4])
      .on('zoom', (event) => {
        transform = event.transform;
      });

    svg.call(zoom);

    // Setup drag behavior for nodes
    setupDrag(d3);
  }

  function setupDrag(_d3) {
    // We'll handle drag in the node elements themselves
  }

  function handleNodeDragStart(event, node) {
    if (!simulation) return;
    isDragging = false;
    dragStartPos = { x: event.clientX, y: event.clientY };
    simulation.alphaTarget(0.3).restart();
    node.fx = node.x;
    node.fy = node.y;
  }

  function handleNodeDrag(event, node) {
    if (event.buttons !== 1) return;
    const dx = Math.abs(event.clientX - dragStartPos.x);
    const dy = Math.abs(event.clientY - dragStartPos.y);
    if (dx > 5 || dy > 5) isDragging = true;

    const rect = svgElement.getBoundingClientRect();
    node.fx = (event.clientX - rect.left - transform.x) / transform.k;
    node.fy = (event.clientY - rect.top - transform.y) / transform.k;
    nodes = [...nodes];
  }

  function handleNodeDragEnd(event, node) {
    if (!simulation) return;
    simulation.alphaTarget(0);
    node.fx = null;
    node.fy = null;

    // If not dragging, treat as click
    if (!isDragging) {
      selectedService.set(node.id);
      fetchServiceDetails(node.id);
    }
    isDragging = false;
  }

  function handleNodeClick(node) {
    // This is now handled in handleNodeDragEnd to avoid conflicts
    // But keep for keyboard navigation
    if (!isDragging) {
      selectedService.set(node.id);
      fetchServiceDetails(node.id);
    }
  }

  function handleNodeHover(event, node) {
    hoveredNode = node;
    tooltipPosition = { x: event.clientX, y: event.clientY };
  }

  function handleNodeLeave() {
    hoveredNode = null;
  }

  function handleBackgroundClick() {
    selectedService.set(null);
    serviceDetails = null;
  }

  // Zoom controls
  async function zoomIn() {
    const d3 = await import('d3');
    const svg = d3.select(svgElement);
    svg.transition().duration(300).call(
      d3.zoom().scaleExtent([0.2, 4]).on('zoom', (e) => { transform = e.transform; }).scaleBy, 1.4
    );
  }

  async function zoomOut() {
    const d3 = await import('d3');
    const svg = d3.select(svgElement);
    svg.transition().duration(300).call(
      d3.zoom().scaleExtent([0.2, 4]).on('zoom', (e) => { transform = e.transform; }).scaleBy, 0.7
    );
  }

  async function fitGraph() {
    const d3 = await import('d3');
    const svg = d3.select(svgElement);
    svg.transition().duration(500).call(
      d3.zoom().scaleExtent([0.2, 4]).on('zoom', (e) => { transform = e.transform; }).transform,
      d3.zoomIdentity.translate(width / 2, height / 2).scale(0.8).translate(-width / 2, -height / 2)
    );
  }

  // Filter nodes
  function isNodeVisible(node) {
    const typeMatch = filters.types[node.type] !== false;
    const healthMatch = filters.health[node.health] !== false;
    const searchMatch = !searchQuery || node.label.toLowerCase().includes(searchQuery.toLowerCase());
    return typeMatch && healthMatch && searchMatch;
  }

  function isLinkVisible(link) {
    const sourceNode = typeof link.source === 'object' ? link.source : nodes.find(n => n.id === link.source);
    const targetNode = typeof link.target === 'object' ? link.target : nodes.find(n => n.id === link.target);
    return sourceNode && targetNode && isNodeVisible(sourceNode) && isNodeVisible(targetNode);
  }

  function formatNumber(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n?.toString() || '0';
  }

  function formatErrorRate(errors, total) {
    if (!total) return '0%';
    return ((errors / total) * 100).toFixed(1) + '%';
  }

  // Navigation functions
  function navigateToLogs(serviceName) {
    if (!serviceName) return;
    query.set(`service:${serviceName}`);
    searchLogs();
    window.location.hash = 'logs';
  }

  function navigateToTraces(_serviceName) {
    // Navigate to traces page - traces will be filtered by service if we add that feature
    window.location.hash = 'traces';
  }

  let selectedRange = '1h';

  function handleRangeChange(range) {
    selectedRange = range;
    fetchServices(range);
    fetchDependencies(range);
    if ($selectedService) fetchServiceDetails($selectedService);
  }

  function updateDimensions() {
    if (containerElement) {
      const rect = containerElement.getBoundingClientRect();
      width = rect.width || 800;
      height = rect.height || 600;
    }
  }

  onMount(async () => {
    updateDimensions();
    window.addEventListener('resize', updateDimensions);
    await fetchServices();
    await fetchDependencies();
  });

  onDestroy(() => {
    if (simulation) simulation.stop();
    window.removeEventListener('resize', updateDimensions);
  });

  // Get link path
  function getLinkPath(link) {
    const source = typeof link.source === 'object' ? link.source : nodes.find(n => n.id === link.source);
    const target = typeof link.target === 'object' ? link.target : nodes.find(n => n.id === link.target);
    if (!source || !target) return '';

    const dx = target.x - source.x;
    const dy = target.y - source.y;
    const dr = Math.sqrt(dx * dx + dy * dy) * 0.8;

    return `M${source.x},${source.y}A${dr},${dr} 0 0,1 ${target.x},${target.y}`;
  }

  // Calculate arrow position
  function getArrowTransform(link) {
    const source = typeof link.source === 'object' ? link.source : nodes.find(n => n.id === link.source);
    const target = typeof link.target === 'object' ? link.target : nodes.find(n => n.id === link.target);
    if (!source || !target) return '';

    const dx = target.x - source.x;
    const dy = target.y - source.y;
    const angle = Math.atan2(dy, dx) * 180 / Math.PI;
    const dist = Math.sqrt(dx * dx + dy * dy);
    const offset = 35; // node radius + arrow offset
    const ratio = (dist - offset) / dist;

    const x = source.x + dx * ratio;
    const y = source.y + dy * ratio;

    return `translate(${x},${y}) rotate(${angle})`;
  }
</script>

<div class="service-map-container">
  <div class="service-map-header">
    <div class="header-left">
      <h2>Service Map</h2>
      <span class="service-count">{nodes.length} services</span>
    </div>

    <div class="header-center">
      <div class="search-box">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/>
        </svg>
        <input type="text" placeholder="Search services..." bind:value={searchQuery} />
      </div>

      <div class="filter-dropdown">
        <button class="filter-btn" on:click={() => showFilters = !showFilters} aria-label="Toggle filters">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>
          </svg>
          Filters
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class:rotated={showFilters}>
            <path d="m6 9 6 6 6-6"/>
          </svg>
        </button>

        {#if showFilters}
          <div class="filter-menu">
            <div class="filter-section">
              <h5>Health Status</h5>
              {#each Object.keys(filters.health) as status}
                <label>
                  <input type="checkbox" bind:checked={filters.health[status]} />
                  <span class="health-indicator health-{status}"></span>
                  <span class="filter-label">{status}</span>
                </label>
              {/each}
            </div>
            <div class="filter-section">
              <h5>Service Type</h5>
              <div class="type-grid">
                {#each serviceTypes.slice(0, 10) as type}
                  <label class="type-checkbox">
                    <input type="checkbox" bind:checked={filters.types[type.type]} />
                    <span class="type-color" style="background: {type.color}"></span>
                    <span class="type-name">{type.label}</span>
                  </label>
                {/each}
              </div>
            </div>
          </div>
        {/if}
      </div>
    </div>

    <div class="controls">
      <div class="time-range">
        {#each ['15m', '1h', '6h', '24h'] as range}
          <button class:active={selectedRange === range} on:click={() => handleRangeChange(range)}>
            {range}
          </button>
        {/each}
      </div>
      <button class="icon-btn" on:click={() => fetchDependencies(selectedRange)} aria-label="Refresh">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M23 4v6h-6M1 20v-6h6M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
        </svg>
      </button>
    </div>
  </div>

  <div class="service-map-body">
    <div class="graph-area" bind:this={containerElement}>
      {#if $loading}
        <div class="loading-state">
          <div class="loading-spinner"></div>
          <span>Loading service map...</span>
        </div>
      {:else if nodes.length === 0}
        <div class="empty-state">
          <div class="empty-icon">
            <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
              <circle cx="12" cy="12" r="3" />
              <circle cx="19" cy="5" r="2" />
              <circle cx="5" cy="5" r="2" />
              <circle cx="19" cy="19" r="2" />
              <circle cx="5" cy="19" r="2" />
              <path d="M12 9V6M12 15v3M9 12H6M15 12h3"/>
            </svg>
          </div>
          <h3>No Services Found</h3>
          <p>Service dependencies will appear here once logs are ingested.</p>
        </div>
      {:else}
        <!-- svelte-ignore a11y_no_noninteractive_tabindex a11y_no_noninteractive_element_interactions -->
        <svg bind:this={svgElement} {width} {height} class="graph-svg" on:click={handleBackgroundClick} on:keydown={(e) => e.key === 'Escape' && handleBackgroundClick()} role="application" aria-label="Interactive Service Map - drag nodes to rearrange, click to select" tabindex="0">
          <defs>
            <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="6" markerHeight="6" orient="auto">
              <path d="M 0 0 L 10 5 L 0 10 z" fill="#4b5563"/>
            </marker>
            <marker id="arrow-error" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="6" markerHeight="6" orient="auto">
              <path d="M 0 0 L 10 5 L 0 10 z" fill="#ef4444"/>
            </marker>
            <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="3" result="blur"/>
              <feMerge>
                <feMergeNode in="blur"/>
                <feMergeNode in="SourceGraphic"/>
              </feMerge>
            </filter>
            <filter id="shadow" x="-50%" y="-50%" width="200%" height="200%">
              <feDropShadow dx="0" dy="2" stdDeviation="4" flood-opacity="0.3"/>
            </filter>
          </defs>

          <g transform="translate({transform.x},{transform.y}) scale({transform.k})">
            <!-- Links -->
            {#each links as link (link.id)}
              {#if isLinkVisible(link)}
                <g class="link-group" class:has-errors={link.hasErrors}>
                  <path
                    class="link"
                    class:error={link.hasErrors}
                    d={getLinkPath(link)}
                    fill="none"
                    stroke={link.hasErrors ? '#ef4444' : '#4b5563'}
                    stroke-width={Math.min(Math.log(link.callCount + 1) * 0.5 + 1.5, 5)}
                    stroke-dasharray={link.hasErrors ? '8,4' : 'none'}
                    marker-end={link.hasErrors ? 'url(#arrow-error)' : 'url(#arrow)'}
                  />
                  {#if link.callCount > 0}
                    <text
                      class="link-label"
                      transform={getArrowTransform(link)}
                      dy="-10"
                      text-anchor="middle"
                      fill="#8b949e"
                      font-size="10"
                    >
                      {formatNumber(link.callCount)}
                    </text>
                  {/if}
                </g>
              {/if}
            {/each}

            <!-- Nodes -->
            {#each nodes as node (node.id)}
              {#if isNodeVisible(node)}
                <g
                  class="node-group"
                  class:selected={$selectedService === node.id}
                  transform="translate({node.x},{node.y})"
                  on:click|stopPropagation={() => handleNodeClick(node)}
                  on:keydown={(e) => e.key === 'Enter' && handleNodeClick(node)}
                  on:mouseenter={(e) => handleNodeHover(e, node)}
                  on:mouseleave={handleNodeLeave}
                  on:mousedown={(e) => handleNodeDragStart(e, node)}
                  on:mousemove={(e) => e.buttons === 1 && handleNodeDrag(e, node)}
                  on:mouseup={(e) => handleNodeDragEnd(e, node)}
                  role="button"
                  tabindex="0"
                  aria-label="Service {node.label}"
                >
                  <!-- Glow effect for selected -->
                  {#if $selectedService === node.id}
                    <rect
                      x="-32"
                      y="-32"
                      width="64"
                      height="64"
                      rx="14"
                      fill="none"
                      stroke="#58a6ff"
                      stroke-width="3"
                      opacity="0.5"
                      filter="url(#glow)"
                    />
                  {/if}

                  <!-- Node background -->
                  <rect
                    x="-28"
                    y="-28"
                    width="56"
                    height="56"
                    rx="12"
                    fill={node.color}
                    filter="url(#shadow)"
                    class="node-bg"
                  />

                  <!-- Health border -->
                  <rect
                    x="-28"
                    y="-28"
                    width="56"
                    height="56"
                    rx="12"
                    fill="none"
                    stroke={node.healthColor}
                    stroke-width="3"
                    class="node-border"
                  />

                  <!-- Abbreviation text -->
                  <text
                    y="5"
                    text-anchor="middle"
                    fill={node.textColor}
                    font-size="14"
                    font-weight="700"
                    font-family="system-ui, -apple-system, sans-serif"
                    class="node-abbrev"
                  >
                    {node.abbrev}
                  </text>

                  <!-- Service name label -->
                  <text
                    y="48"
                    text-anchor="middle"
                    fill="#c9d1d9"
                    font-size="11"
                    font-weight="500"
                    class="node-label"
                  >
                    {node.label.length > 15 ? node.label.slice(0, 14) + '...' : node.label}
                  </text>
                </g>
              {/if}
            {/each}
          </g>
        </svg>
      {/if}

      <div class="graph-controls">
        <button on:click={zoomIn} title="Zoom In" aria-label="Zoom in">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35M11 8v6M8 11h6"/>
          </svg>
        </button>
        <button on:click={zoomOut} title="Zoom Out" aria-label="Zoom out">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35M8 11h6"/>
          </svg>
        </button>
        <button on:click={fitGraph} title="Fit to View" aria-label="Fit to view">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M8 3H5a2 2 0 00-2 2v3M21 8V5a2 2 0 00-2-2h-3M3 16v3a2 2 0 002 2h3M16 21h3a2 2 0 002-2v-3"/>
          </svg>
        </button>
      </div>

      {#if hoveredNode}
        <div class="hover-tooltip" style="left: {tooltipPosition.x + 15}px; top: {tooltipPosition.y - 10}px;">
          <div class="tooltip-header">
            <div class="tooltip-icon" style="background: {hoveredNode.color}; color: {hoveredNode.textColor}">
              {hoveredNode.abbrev}
            </div>
            <div class="tooltip-info">
              <span class="tooltip-name">{hoveredNode.label}</span>
              <span class="tooltip-type">{hoveredNode.typeLabel}</span>
            </div>
            <span class="health-pill health-{hoveredNode.health}">{hoveredNode.health}</span>
          </div>
          <div class="tooltip-metrics">
            <div class="metric">
              <span class="metric-value">{formatNumber(hoveredNode.logCount)}</span>
              <span class="metric-label">requests</span>
            </div>
            <div class="metric">
              <span class="metric-value error">{formatNumber(hoveredNode.errorCount)}</span>
              <span class="metric-label">errors</span>
            </div>
            <div class="metric">
              <span class="metric-value">{formatErrorRate(hoveredNode.errorCount, hoveredNode.logCount)}</span>
              <span class="metric-label">error rate</span>
            </div>
          </div>
        </div>
      {/if}
    </div>

    {#if $selectedService && serviceDetails}
      {@const typeInfo = detectServiceType($selectedService)}
      {@const health = serviceDetails.metrics ? getHealthStatus(serviceDetails.metrics.error_count, serviceDetails.metrics.total_logs) : { status: 'unknown' }}
      <div class="details-panel">
        <div class="panel-header">
          <div class="service-header">
            <div class="service-icon" style="background: {typeInfo.color}; color: {typeInfo.textColor}">
              {typeInfo.abbrev}
            </div>
            <div class="service-info">
              <h3>{$selectedService}</h3>
              <div class="service-badges">
                <span class="badge type-badge">{typeInfo.label}</span>
                <span class="badge health-badge health-{health.status}">{health.status}</span>
              </div>
            </div>
          </div>
          <button class="close-btn" on:click={() => { selectedService.set(null); serviceDetails = null; }} aria-label="Close panel">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M18 6L6 18M6 6l12 12"/>
            </svg>
          </button>
        </div>

        {#if detailsLoading}
          <div class="panel-loading">
            <div class="loading-spinner small"></div>
          </div>
        {:else if serviceDetails.metrics}
          <div class="panel-body">
            <div class="metrics-grid">
              <div class="metric-card">
                <div class="metric-card-value">{formatNumber(serviceDetails.metrics.total_logs || 0)}</div>
                <div class="metric-card-label">Requests</div>
              </div>
              <div class="metric-card">
                <div class="metric-card-value error">{formatNumber(serviceDetails.metrics.error_count || 0)}</div>
                <div class="metric-card-label">Errors</div>
              </div>
              <div class="metric-card">
                <div class="metric-card-value">{formatErrorRate(serviceDetails.metrics.error_count, serviceDetails.metrics.total_logs)}</div>
                <div class="metric-card-label">Error Rate</div>
              </div>
              <div class="metric-card">
                <div class="metric-card-value">{latencyData.percentiles?.avg_ms?.toFixed(1) || '0'}ms</div>
                <div class="metric-card-label">Avg Latency</div>
              </div>
            </div>

            {#if metricsData.length > 0}
              <div class="chart-card">
                <h4>Requests & Errors</h4>
                <ServiceMetricsChart data={metricsData} height={100} />
              </div>
            {/if}

            {#if latencyData.percentiles && Object.keys(latencyData.percentiles).length > 0}
              <div class="chart-card">
                <h4>Latency Percentiles</h4>
                <ServiceLatencyChart percentiles={latencyData.percentiles} height={90} />
              </div>
            {/if}

            {#if serviceDetails.recent_errors?.length > 0}
              <div class="errors-card">
                <h4>Recent Errors ({serviceDetails.recent_errors.length})</h4>
                <div class="errors-list">
                  {#each serviceDetails.recent_errors.slice(0, 5) as error}
                    <div class="error-row">
                      <div class="error-time">{new Date(error.ts).toLocaleTimeString()}</div>
                      <div class="error-message">{error.message}</div>
                    </div>
                  {/each}
                </div>
              </div>
            {/if}

            {#if serviceDetails.recent_logs?.length > 0}
              <div class="logs-card">
                <h4>Recent Logs</h4>
                <div class="logs-list">
                  {#each serviceDetails.recent_logs.slice(0, 5) as log}
                    <div class="log-row" class:error-log={log.level === 'ERROR' || log.level === 'FATAL'}>
                      <span class="log-time">{new Date(log.ts).toLocaleTimeString()}</span>
                      <span class="log-level level-{log.level?.toLowerCase()}">{log.level}</span>
                      <span class="log-msg">{log.message?.slice(0, 50)}{log.message?.length > 50 ? '...' : ''}</span>
                    </div>
                  {/each}
                </div>
              </div>
            {/if}

            <div class="action-buttons">
              <a href="#logs" class="action-btn" on:click={() => navigateToLogs($selectedService)}>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
                  <path d="M14 2v6h6M16 13H8M16 17H8"/>
                </svg>
                View Logs
              </a>
              <a href="#traces" class="action-btn" on:click={() => navigateToTraces($selectedService)}>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
                </svg>
                View Traces
              </a>
            </div>
          </div>
        {/if}
      </div>
    {/if}
  </div>

  <div class="map-legend">
    <div class="legend-section">
      <span class="legend-title">Health:</span>
      <div class="legend-item"><span class="legend-dot healthy"></span>Healthy</div>
      <div class="legend-item"><span class="legend-dot degraded"></span>Degraded</div>
      <div class="legend-item"><span class="legend-dot critical"></span>Critical</div>
    </div>
    <div class="legend-divider"></div>
    <div class="legend-section">
      <span class="legend-title">Connections:</span>
      <div class="legend-item"><span class="legend-line normal"></span>Normal</div>
      <div class="legend-item"><span class="legend-line error"></span>With Errors</div>
    </div>
  </div>
</div>

<style>
  .service-map-container {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: #0d1117;
    color: #c9d1d9;
  }

  /* Header */
  .service-map-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 20px;
    border-bottom: 1px solid #21262d;
    background: #161b22;
    gap: 20px;
  }

  .header-left {
    display: flex;
    align-items: baseline;
    gap: 10px;
  }

  .header-left h2 {
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    color: #f0f6fc;
  }

  .service-count {
    font-size: 12px;
    color: #8b949e;
    background: #21262d;
    padding: 3px 8px;
    border-radius: 10px;
  }

  .header-center {
    display: flex;
    gap: 12px;
    flex: 1;
    max-width: 480px;
  }

  .search-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 14px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    flex: 1;
    color: #8b949e;
    transition: border-color 0.2s;
  }

  .search-box:focus-within {
    border-color: #58a6ff;
  }

  .search-box input {
    flex: 1;
    border: none;
    background: transparent;
    color: #c9d1d9;
    font-size: 14px;
    outline: none;
  }

  .search-box input::placeholder {
    color: #6e7681;
  }

  /* Filter Dropdown */
  .filter-dropdown {
    position: relative;
  }

  .filter-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 14px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    color: #c9d1d9;
    font-size: 13px;
    cursor: pointer;
    transition: all 0.2s;
  }

  .filter-btn:hover {
    border-color: #58a6ff;
  }

  .filter-btn svg.rotated {
    transform: rotate(180deg);
  }

  .filter-menu {
    position: absolute;
    top: calc(100% + 6px);
    left: 0;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 12px;
    padding: 14px;
    z-index: 100;
    min-width: 260px;
    box-shadow: 0 12px 40px rgba(0,0,0,0.5);
  }

  .filter-section {
    margin-bottom: 14px;
  }

  .filter-section:last-child {
    margin-bottom: 0;
  }

  .filter-section h5 {
    margin: 0 0 10px;
    font-size: 11px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .filter-section label {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 5px 0;
    font-size: 13px;
    color: #c9d1d9;
    cursor: pointer;
  }

  .health-indicator {
    width: 10px;
    height: 10px;
    border-radius: 50%;
  }

  .health-indicator.health-healthy { background: #10b981; }
  .health-indicator.health-degraded { background: #f59e0b; }
  .health-indicator.health-critical { background: #ef4444; }
  .health-indicator.health-unknown { background: #6b7280; }

  .type-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 6px;
  }

  .type-checkbox {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
  }

  .type-color {
    width: 12px;
    height: 12px;
    border-radius: 3px;
  }

  /* Controls */
  .controls {
    display: flex;
    gap: 10px;
    align-items: center;
  }

  .time-range {
    display: flex;
    gap: 2px;
    background: #21262d;
    padding: 4px;
    border-radius: 8px;
  }

  .time-range button {
    padding: 6px 14px;
    border: none;
    background: transparent;
    color: #8b949e;
    border-radius: 6px;
    cursor: pointer;
    font-size: 13px;
    font-weight: 500;
    transition: all 0.15s;
  }

  .time-range button:hover {
    color: #c9d1d9;
    background: rgba(255,255,255,0.05);
  }

  .time-range button.active {
    background: #58a6ff;
    color: #fff;
  }

  .icon-btn {
    padding: 8px;
    border: 1px solid #30363d;
    background: #0d1117;
    color: #8b949e;
    border-radius: 8px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.2s;
  }

  .icon-btn:hover {
    background: #21262d;
    color: #f0f6fc;
    border-color: #58a6ff;
  }

  /* Body Layout */
  .service-map-body {
    flex: 1;
    display: flex;
    position: relative;
    overflow: hidden;
  }

  .graph-area {
    flex: 1;
    position: relative;
    overflow: hidden;
  }

  .graph-svg {
    width: 100%;
    height: 100%;
    cursor: grab;
  }

  .graph-svg:active {
    cursor: grabbing;
  }

  /* Loading & Empty States */
  .loading-state,
  .empty-state {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    background: rgba(13, 17, 23, 0.95);
  }

  .loading-spinner {
    width: 36px;
    height: 36px;
    border: 3px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .loading-spinner.small {
    width: 24px;
    height: 24px;
    border-width: 2px;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .empty-state {
    text-align: center;
    color: #8b949e;
  }

  .empty-icon {
    opacity: 0.4;
  }

  .empty-state h3 {
    margin: 0;
    font-size: 16px;
    color: #c9d1d9;
  }

  .empty-state p {
    margin: 0;
    font-size: 14px;
  }

  /* Graph Controls */
  .graph-controls {
    position: absolute;
    bottom: 20px;
    left: 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
    padding: 6px;
  }

  .graph-controls button {
    width: 36px;
    height: 36px;
    border: none;
    background: transparent;
    color: #8b949e;
    border-radius: 6px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s;
  }

  .graph-controls button:hover {
    background: #21262d;
    color: #f0f6fc;
  }

  /* SVG Nodes & Links */
  .node-group {
    cursor: pointer;
    transition: transform 0.15s;
  }

  .node-group:hover .node-bg {
    filter: url(#shadow) brightness(1.15);
  }

  .node-group:hover .node-border {
    stroke-width: 4;
  }

  .node-group.selected .node-border {
    stroke: #58a6ff;
    stroke-width: 4;
  }

  .node-abbrev {
    pointer-events: none;
    user-select: none;
  }

  .node-label {
    pointer-events: none;
    user-select: none;
  }

  .link {
    transition: stroke-width 0.2s, opacity 0.2s;
    opacity: 0.7;
  }

  .link:hover {
    opacity: 1;
    stroke-width: 4 !important;
  }

  .link.error {
    animation: dash 1s linear infinite;
  }

  @keyframes dash {
    to {
      stroke-dashoffset: -24;
    }
  }

  .link-label {
    pointer-events: none;
    user-select: none;
  }

  /* Hover Tooltip */
  .hover-tooltip {
    position: fixed;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 12px;
    padding: 14px;
    pointer-events: none;
    z-index: 1000;
    box-shadow: 0 12px 32px rgba(0,0,0,0.5);
    min-width: 220px;
  }

  .tooltip-header {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 12px;
  }

  .tooltip-icon {
    width: 36px;
    height: 36px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 700;
    font-size: 12px;
    font-family: system-ui, -apple-system, sans-serif;
  }

  .tooltip-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .tooltip-name {
    font-weight: 600;
    color: #f0f6fc;
    font-size: 14px;
  }

  .tooltip-type {
    font-size: 11px;
    color: #8b949e;
  }

  .health-pill {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    padding: 3px 8px;
    border-radius: 10px;
  }

  .health-pill.health-healthy { background: rgba(16, 185, 129, 0.2); color: #10b981; }
  .health-pill.health-degraded { background: rgba(245, 158, 11, 0.2); color: #f59e0b; }
  .health-pill.health-critical { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
  .health-pill.health-unknown { background: rgba(107, 114, 128, 0.2); color: #6b7280; }

  .tooltip-metrics {
    display: flex;
    gap: 16px;
    padding-top: 10px;
    border-top: 1px solid #21262d;
  }

  .metric {
    display: flex;
    flex-direction: column;
  }

  .metric-value {
    font-size: 15px;
    font-weight: 600;
    color: #f0f6fc;
  }

  .metric-value.error {
    color: #ef4444;
  }

  .metric-label {
    font-size: 10px;
    color: #8b949e;
  }

  /* Details Panel */
  .details-panel {
    width: 340px;
    background: #161b22;
    border-left: 1px solid #21262d;
    display: flex;
    flex-direction: column;
    animation: slideIn 0.25s ease-out;
  }

  @keyframes slideIn {
    from { transform: translateX(30px); opacity: 0; }
    to { transform: translateX(0); opacity: 1; }
  }

  .panel-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding: 16px;
    border-bottom: 1px solid #21262d;
  }

  .service-header {
    display: flex;
    gap: 12px;
    align-items: center;
  }

  .service-icon {
    width: 44px;
    height: 44px;
    border-radius: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 700;
    font-size: 14px;
    font-family: system-ui, -apple-system, sans-serif;
  }

  .service-info h3 {
    margin: 0;
    font-size: 15px;
    font-weight: 600;
    color: #f0f6fc;
  }

  .service-badges {
    display: flex;
    gap: 6px;
    margin-top: 6px;
  }

  .badge {
    font-size: 10px;
    font-weight: 600;
    padding: 3px 8px;
    border-radius: 4px;
  }

  .type-badge {
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
  }

  .health-badge {
    text-transform: uppercase;
  }

  .health-badge.health-healthy { background: rgba(16, 185, 129, 0.2); color: #10b981; }
  .health-badge.health-degraded { background: rgba(245, 158, 11, 0.2); color: #f59e0b; }
  .health-badge.health-critical { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
  .health-badge.health-unknown { background: rgba(107, 114, 128, 0.2); color: #6b7280; }

  .close-btn {
    padding: 6px;
    border: none;
    background: transparent;
    color: #8b949e;
    cursor: pointer;
    border-radius: 6px;
    transition: all 0.15s;
  }

  .close-btn:hover {
    color: #f0f6fc;
    background: #21262d;
  }

  .panel-loading {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 60px;
  }

  .panel-body {
    flex: 1;
    overflow-y: auto;
    padding: 14px;
  }

  .metrics-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
    margin-bottom: 14px;
  }

  .metric-card {
    padding: 12px;
    background: #0d1117;
    border: 1px solid #21262d;
    border-radius: 10px;
  }

  .metric-card-value {
    font-size: 20px;
    font-weight: 700;
    color: #f0f6fc;
  }

  .metric-card-value.error {
    color: #ef4444;
  }

  .metric-card-label {
    font-size: 11px;
    color: #8b949e;
    margin-top: 2px;
  }

  .chart-card {
    margin-bottom: 14px;
    padding: 14px;
    background: #0d1117;
    border: 1px solid #21262d;
    border-radius: 10px;
  }

  .chart-card h4 {
    margin: 0 0 10px;
    font-size: 12px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .errors-card {
    padding: 14px;
    background: #0d1117;
    border: 1px solid #21262d;
    border-radius: 10px;
  }

  .errors-card h4 {
    margin: 0 0 10px;
    font-size: 12px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .errors-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
    max-height: 200px;
    overflow-y: auto;
  }

  .error-row {
    padding: 10px;
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid rgba(239, 68, 68, 0.15);
    border-radius: 8px;
  }

  .error-time {
    font-size: 10px;
    color: #8b949e;
    margin-bottom: 4px;
  }

  .error-message {
    font-size: 12px;
    color: #f0f6fc;
    line-height: 1.4;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  /* Legend */
  .map-legend {
    display: flex;
    align-items: center;
    gap: 20px;
    padding: 10px 20px;
    border-top: 1px solid #21262d;
    background: #161b22;
  }

  .legend-section {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .legend-title {
    font-size: 11px;
    font-weight: 600;
    color: #8b949e;
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: #8b949e;
  }

  .legend-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
  }

  .legend-dot.healthy { background: #10b981; }
  .legend-dot.degraded { background: #f59e0b; }
  .legend-dot.critical { background: #ef4444; }

  .legend-divider {
    width: 1px;
    height: 20px;
    background: #30363d;
  }

  .legend-line {
    width: 24px;
    height: 3px;
    border-radius: 2px;
  }

  .legend-line.normal {
    background: #4b5563;
  }

  .legend-line.error {
    background: repeating-linear-gradient(
      90deg,
      #ef4444 0px,
      #ef4444 4px,
      transparent 4px,
      transparent 7px
    );
  }

  /* Recent Logs Card */
  .logs-card {
    padding: 14px;
    background: #0d1117;
    border: 1px solid #21262d;
    border-radius: 10px;
    margin-bottom: 14px;
  }

  .logs-card h4 {
    margin: 0 0 10px;
    font-size: 12px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .logs-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .log-row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px;
    background: #161b22;
    border-radius: 6px;
    font-size: 11px;
  }

  .log-row.error-log {
    background: rgba(239, 68, 68, 0.1);
    border: 1px solid rgba(239, 68, 68, 0.2);
  }

  .log-time {
    color: #6e7681;
    font-family: 'SFMono-Regular', Consolas, monospace;
    flex-shrink: 0;
  }

  .log-level {
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 9px;
    font-weight: 600;
    text-transform: uppercase;
    flex-shrink: 0;
  }

  .level-info { background: #3b82f6; color: #fff; }
  .level-debug { background: #6b7280; color: #fff; }
  .level-warn, .level-warning { background: #f59e0b; color: #000; }
  .level-error, .level-fatal { background: #ef4444; color: #fff; }

  .log-msg {
    color: #c9d1d9;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  }

  /* Action Buttons */
  .action-buttons {
    display: flex;
    gap: 10px;
    margin-top: 14px;
  }

  .action-btn {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 12px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 8px;
    color: #c9d1d9;
    font-size: 13px;
    font-weight: 500;
    text-decoration: none;
    cursor: pointer;
    transition: all 0.2s;
  }

  .action-btn:hover {
    background: #30363d;
    border-color: #58a6ff;
    color: #f0f6fc;
  }

  .action-btn svg {
    opacity: 0.7;
  }

  .action-btn:hover svg {
    opacity: 1;
  }
</style>
