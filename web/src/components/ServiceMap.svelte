<script>
  import { onMount, onDestroy } from 'svelte';
  import { writable } from 'svelte/store';
  import { detectServiceType, getHealthColor, serviceTypes } from '../lib/serviceIcons.js';
  import ServiceMetricsChart from './ServiceMetricsChart.svelte';
  import ServiceLatencyChart from './ServiceLatencyChart.svelte';

  // Stores
  export const services = writable([]);
  export const dependencies = writable({ nodes: [], edges: [] });
  export const loading = writable(false);
  export const selectedService = writable(null);

  let container;
  let cy = null;
  let serviceDetails = null;
  let detailsLoading = false;
  let hoveredNode = null;
  let tooltipPosition = { x: 0, y: 0 };
  let searchQuery = '';
  let showFilters = false;
  let metricsData = [];
  let latencyData = { percentiles: {}, timeseries: [] };

  // Filters
  let filters = {
    types: {},
    health: { healthy: true, degraded: true, critical: true, unknown: true }
  };

  // Initialize type filters
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
        if (cy) {
          renderGraph(data);
        }
      }
    } catch (err) {
      console.error('Failed to fetch dependencies:', err);
    } finally {
      loading.set(false);
    }
  }

  // Fetch service details with metrics and latency
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

      if (detailsRes.ok) {
        serviceDetails = await detailsRes.json();
      }
      if (metricsRes.ok) {
        const data = await metricsRes.json();
        metricsData = data.data || [];
      }
      if (latencyRes.ok) {
        latencyData = await latencyRes.json();
      }
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

  // Initialize Cytoscape
  async function initCytoscape() {
    if (!container) return;

    const cytoscape = (await import('cytoscape')).default;

    cy = cytoscape({
      container,
      style: [
        {
          selector: 'node',
          style: {
            'background-color': '#1e2530',
            'background-image': 'data(iconUrl)',
            'background-fit': 'contain',
            'background-clip': 'none',
            'background-width': '60%',
            'background-height': '60%',
            'label': 'data(label)',
            'text-valign': 'bottom',
            'text-halign': 'center',
            'font-size': '11px',
            'font-weight': '500',
            'color': '#c9d1d9',
            'text-margin-y': 8,
            'text-outline-color': '#0d1117',
            'text-outline-width': 2,
            'width': 52,
            'height': 52,
            'border-width': 3,
            'border-color': 'data(healthColor)',
            'border-opacity': 1,
            'shadow-blur': 12,
            'shadow-color': 'data(healthColor)',
            'shadow-opacity': 0.4,
            'shadow-offset-x': 0,
            'shadow-offset-y': 0,
          }
        },
        {
          selector: 'node:hover',
          style: {
            'width': 60,
            'height': 60,
            'border-width': 4,
            'shadow-blur': 20,
            'shadow-opacity': 0.6,
            'z-index': 999,
          }
        },
        {
          selector: 'node:selected',
          style: {
            'border-color': '#58a6ff',
            'border-width': 4,
            'shadow-blur': 25,
            'shadow-color': '#58a6ff',
            'shadow-opacity': 0.7,
          }
        },
        {
          selector: 'node.hidden',
          style: {
            'display': 'none'
          }
        },
        {
          selector: 'edge',
          style: {
            'width': 'data(weight)',
            'line-color': '#4b5563',
            'target-arrow-color': '#4b5563',
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            'arrow-scale': 1.1,
            'opacity': 0.6,
          }
        },
        {
          selector: 'edge.error',
          style: {
            'line-color': '#ef4444',
            'target-arrow-color': '#ef4444',
          }
        },
        {
          selector: 'edge:hover',
          style: {
            'width': 4,
            'opacity': 1,
          }
        },
        {
          selector: 'edge.hidden',
          style: {
            'display': 'none'
          }
        }
      ],
      layout: { name: 'cose', idealEdgeLength: 160, nodeRepulsion: 400000, animate: true, animationDuration: 600 },
      minZoom: 0.2,
      maxZoom: 4,
      wheelSensitivity: 0.3,
    });

    // Node hover
    cy.on('mouseover', 'node', (event) => {
      const node = event.target;
      const pos = node.renderedPosition();
      hoveredNode = {
        id: node.id(),
        label: node.data('label'),
        logCount: node.data('logCount'),
        errorCount: node.data('errorCount'),
        health: node.data('health'),
        serviceType: node.data('serviceType'),
      };
      tooltipPosition = { x: pos.x, y: pos.y - 40 };
    });

    cy.on('mouseout', 'node', () => { hoveredNode = null; });

    // Node click
    cy.on('tap', 'node', async (event) => {
      const node = event.target;
      selectedService.set(node.id());
      await fetchServiceDetails(node.id());
    });

    // Background click
    cy.on('tap', (event) => {
      if (event.target === cy) {
        selectedService.set(null);
        serviceDetails = null;
      }
    });
  }

  // Render graph
  function renderGraph(data) {
    if (!cy) return;
    cy.elements().remove();

    const nodes = (data.nodes || []).map(n => {
      const health = getHealthStatus(n.data.error_count, n.data.log_count);
      const typeInfo = detectServiceType(n.data.id);
      return {
        data: {
          id: n.data.id,
          label: n.data.label || n.data.id,
          iconUrl: typeInfo.icon,
          healthColor: health.color,
          logCount: n.data.log_count || 0,
          errorCount: n.data.error_count || 0,
          health: health.status,
          serviceType: typeInfo.type,
        }
      };
    });

    const edges = (data.edges || []).map(e => ({
      data: {
        id: e.data.id,
        source: e.data.source,
        target: e.data.target,
        weight: Math.min(Math.log(e.data.call_count + 1) * 0.7 + 1.2, 5),
        callCount: e.data.call_count || 0,
        errorCount: e.data.error_count || 0,
      },
      classes: e.data.error_count > 0 ? 'error' : ''
    }));

    cy.add([...nodes, ...edges]);
    cy.layout({ name: 'cose', idealEdgeLength: 160, nodeRepulsion: 400000, animate: true, animationDuration: 600 }).run();
    setTimeout(() => cy.fit(undefined, 50), 700);
    applyFilters();
  }

  // Apply filters
  function applyFilters() {
    if (!cy) return;

    cy.nodes().forEach(node => {
      const type = node.data('serviceType');
      const health = node.data('health');
      const label = node.data('label')?.toLowerCase() || '';
      const query = searchQuery.toLowerCase();

      const typeMatch = filters.types[type] !== false;
      const healthMatch = filters.health[health] !== false;
      const searchMatch = !query || label.includes(query);

      if (typeMatch && healthMatch && searchMatch) {
        node.removeClass('hidden');
      } else {
        node.addClass('hidden');
      }
    });

    // Hide edges connected to hidden nodes
    cy.edges().forEach(edge => {
      const source = edge.source();
      const target = edge.target();
      if (source.hasClass('hidden') || target.hasClass('hidden')) {
        edge.addClass('hidden');
      } else {
        edge.removeClass('hidden');
      }
    });
  }

  // Zoom controls
  function zoomIn() { if (cy) cy.zoom(cy.zoom() * 1.3); }
  function zoomOut() { if (cy) cy.zoom(cy.zoom() / 1.3); }
  function fitGraph() { if (cy) cy.fit(undefined, 50); }

  function formatNumber(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n?.toString() || '0';
  }

  function formatErrorRate(errors, total) {
    if (!total) return '0%';
    return ((errors / total) * 100).toFixed(1) + '%';
  }

  let selectedRange = '1h';

  function handleRangeChange(range) {
    selectedRange = range;
    fetchServices(range);
    fetchDependencies(range);
    if ($selectedService) fetchServiceDetails($selectedService);
  }

  $: if (searchQuery !== undefined && cy) {
    applyFilters();
  }

  onMount(async () => {
    await new Promise(r => setTimeout(r, 100));
    await initCytoscape();
    await fetchServices();
    await fetchDependencies();
  });

  $: if (cy && $dependencies.nodes?.length > 0) {
    renderGraph($dependencies);
  }

  onDestroy(() => { if (cy) cy.destroy(); });
</script>

<div class="service-map-container">
  <div class="service-map-header">
    <div class="header-left">
      <h2>Service Map</h2>
      <span class="subtitle">{$dependencies.nodes?.length || 0} services</span>
    </div>

    <div class="header-center">
      <div class="search-box">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/>
        </svg>
        <input type="text" placeholder="Search services..." bind:value={searchQuery} />
      </div>

      <div class="filter-dropdown">
        <button class="filter-btn" on:click={() => showFilters = !showFilters}>
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
                  <input type="checkbox" bind:checked={filters.health[status]} on:change={applyFilters} />
                  <span class="health-dot health-{status}"></span>
                  {status}
                </label>
              {/each}
            </div>
            <div class="filter-section">
              <h5>Service Type</h5>
              <div class="type-filters">
                {#each serviceTypes.slice(0, 8) as type}
                  <label class="type-label">
                    <input type="checkbox" bind:checked={filters.types[type.type]} on:change={applyFilters} />
                    {type.label}
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
      <button class="refresh-btn" on:click={() => fetchDependencies(selectedRange)} aria-label="Refresh">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M23 4v6h-6M1 20v-6h6M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
        </svg>
      </button>
    </div>
  </div>

  <div class="service-map-content">
    <div class="graph-wrapper">
      <div class="graph-container" bind:this={container}>
        {#if $loading}
          <div class="loading-overlay">
            <div class="spinner"></div>
            <span>Loading...</span>
          </div>
        {:else if !$dependencies.nodes || $dependencies.nodes.length === 0}
          <div class="empty-state">
            <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1">
              <circle cx="12" cy="12" r="3" /><circle cx="19" cy="5" r="2" /><circle cx="5" cy="5" r="2" />
              <circle cx="19" cy="19" r="2" /><circle cx="5" cy="19" r="2" />
              <path d="M12 9V6M12 15v3M9 12H6M15 12h3"/>
            </svg>
            <h3>No Services Found</h3>
            <p>Service dependencies will appear here once logs are ingested.</p>
          </div>
        {/if}
      </div>

      <div class="zoom-controls">
        <button on:click={zoomIn} title="Zoom In">+</button>
        <button on:click={zoomOut} title="Zoom Out">-</button>
        <button on:click={fitGraph} title="Fit">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/>
          </svg>
        </button>
      </div>

      {#if hoveredNode}
        <div class="node-tooltip" style="left: {tooltipPosition.x}px; top: {tooltipPosition.y}px;">
          <div class="tooltip-header">
            <span class="tooltip-name">{hoveredNode.label}</span>
            <span class="tooltip-health health-{hoveredNode.health}">{hoveredNode.health}</span>
          </div>
          <div class="tooltip-stats">
            <div class="stat"><span class="stat-value">{formatNumber(hoveredNode.logCount)}</span><span class="stat-label">logs</span></div>
            <div class="stat"><span class="stat-value error">{formatNumber(hoveredNode.errorCount)}</span><span class="stat-label">errors</span></div>
            <div class="stat"><span class="stat-value">{formatErrorRate(hoveredNode.errorCount, hoveredNode.logCount)}</span><span class="stat-label">rate</span></div>
          </div>
        </div>
      {/if}
    </div>

    {#if $selectedService && serviceDetails}
      {@const typeInfo = detectServiceType($selectedService)}
      {@const health = serviceDetails.metrics ? getHealthStatus(serviceDetails.metrics.error_count, serviceDetails.metrics.total_logs) : { status: 'unknown' }}
      <div class="service-panel">
        <div class="panel-header">
          <div class="service-info">
            <div class="service-icon-wrapper">
              <img src={typeInfo.icon} alt={typeInfo.label} class="type-icon" />
            </div>
            <div>
              <h3>{$selectedService}</h3>
              <div class="service-meta">
                <span class="type-badge">{typeInfo.label}</span>
                <span class="health-badge health-{health.status}">{health.status}</span>
              </div>
            </div>
          </div>
          <button class="close-btn" on:click={() => { selectedService.set(null); serviceDetails = null; }} aria-label="Close">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M18 6L6 18M6 6l12 12"/>
            </svg>
          </button>
        </div>

        {#if detailsLoading}
          <div class="loading-panel"><div class="spinner-small"></div></div>
        {:else if serviceDetails.metrics}
          <div class="panel-content">
            <div class="stats-grid">
              <div class="stat-card">
                <span class="stat-value">{formatNumber(serviceDetails.metrics.total_logs || 0)}</span>
                <span class="stat-label">Requests</span>
              </div>
              <div class="stat-card">
                <span class="stat-value error">{formatNumber(serviceDetails.metrics.error_count || 0)}</span>
                <span class="stat-label">Errors</span>
              </div>
              <div class="stat-card">
                <span class="stat-value">{formatErrorRate(serviceDetails.metrics.error_count, serviceDetails.metrics.total_logs)}</span>
                <span class="stat-label">Error Rate</span>
              </div>
              <div class="stat-card">
                <span class="stat-value">{latencyData.percentiles?.avg_ms?.toFixed(1) || '0'}ms</span>
                <span class="stat-label">Avg Latency</span>
              </div>
            </div>

            {#if metricsData.length > 0}
              <div class="chart-section">
                <h4>Requests & Errors</h4>
                <ServiceMetricsChart data={metricsData} height={100} />
              </div>
            {/if}

            {#if latencyData.percentiles && Object.keys(latencyData.percentiles).length > 0}
              <div class="chart-section">
                <h4>Latency Percentiles</h4>
                <ServiceLatencyChart percentiles={latencyData.percentiles} height={90} />
              </div>
            {/if}

            {#if serviceDetails.recent_errors?.length > 0}
              <div class="errors-section">
                <h4>Recent Errors ({serviceDetails.recent_errors.length})</h4>
                <div class="error-list">
                  {#each serviceDetails.recent_errors.slice(0, 5) as error}
                    <div class="error-item">
                      <div class="error-time">{new Date(error.ts).toLocaleTimeString()}</div>
                      <div class="error-msg">{error.message}</div>
                    </div>
                  {/each}
                </div>
              </div>
            {/if}
          </div>
        {/if}
      </div>
    {/if}
  </div>

  <div class="legend">
    <div class="legend-item"><span class="legend-dot healthy"></span>Healthy</div>
    <div class="legend-item"><span class="legend-dot degraded"></span>Degraded</div>
    <div class="legend-item"><span class="legend-dot critical"></span>Critical</div>
    <div class="legend-divider"></div>
    <div class="legend-item"><span class="legend-line normal"></span>Normal</div>
    <div class="legend-item"><span class="legend-line error"></span>Errors</div>
  </div>
</div>

<style>
  .service-map-container {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: linear-gradient(180deg, #0d1117 0%, #161b22 100%);
  }

  .service-map-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid #30363d;
    background: rgba(22, 27, 34, 0.9);
    backdrop-filter: blur(8px);
    gap: 16px;
  }

  .header-left h2 { margin: 0; font-size: 16px; font-weight: 600; color: #f0f6fc; }
  .subtitle { font-size: 11px; color: #8b949e; }

  .header-center {
    display: flex;
    gap: 10px;
    flex: 1;
    max-width: 500px;
  }

  .search-box {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 8px;
    flex: 1;
    color: #8b949e;
  }

  .search-box input {
    flex: 1;
    border: none;
    background: transparent;
    color: #c9d1d9;
    font-size: 13px;
    outline: none;
  }

  .search-box input::placeholder { color: #6e7681; }

  .filter-dropdown { position: relative; }

  .filter-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 8px;
    color: #c9d1d9;
    font-size: 13px;
    cursor: pointer;
    transition: all 0.2s;
  }

  .filter-btn:hover { border-color: #8b949e; }
  .filter-btn svg.rotated { transform: rotate(180deg); }

  .filter-menu {
    position: absolute;
    top: calc(100% + 4px);
    left: 0;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 10px;
    padding: 12px;
    z-index: 100;
    min-width: 220px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.4);
  }

  .filter-section { margin-bottom: 12px; }
  .filter-section:last-child { margin-bottom: 0; }
  .filter-section h5 { margin: 0 0 8px; font-size: 11px; color: #8b949e; text-transform: uppercase; }

  .filter-section label {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 0;
    font-size: 12px;
    color: #c9d1d9;
    cursor: pointer;
  }

  .health-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
  }

  .health-dot.health-healthy { background: #10b981; }
  .health-dot.health-degraded { background: #f59e0b; }
  .health-dot.health-critical { background: #ef4444; }
  .health-dot.health-unknown { background: #6b7280; }

  .type-filters {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 4px;
  }

  .type-label { font-size: 11px; }

  .controls { display: flex; gap: 8px; align-items: center; }

  .time-range {
    display: flex;
    gap: 2px;
    background: #21262d;
    padding: 3px;
    border-radius: 8px;
  }

  .time-range button {
    padding: 5px 12px;
    border: none;
    background: transparent;
    color: #8b949e;
    border-radius: 6px;
    cursor: pointer;
    font-size: 12px;
    font-weight: 500;
    transition: all 0.2s;
  }

  .time-range button:hover { color: #c9d1d9; }
  .time-range button.active { background: #388bfd; color: #fff; }

  .refresh-btn {
    padding: 8px;
    border: 1px solid #30363d;
    background: #21262d;
    color: #c9d1d9;
    border-radius: 8px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .refresh-btn:hover { background: #30363d; }

  .service-map-content {
    flex: 1;
    display: flex;
    position: relative;
    overflow: hidden;
  }

  .graph-wrapper { flex: 1; position: relative; }
  .graph-container { width: 100%; height: 100%; min-height: 400px; }

  .loading-overlay {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    background: rgba(13, 17, 23, 0.9);
    color: #8b949e;
  }

  .empty-state {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
    color: #8b949e;
  }

  .empty-state svg { opacity: 0.3; margin-bottom: 12px; }
  .empty-state h3 { margin: 0 0 6px; font-size: 16px; color: #c9d1d9; }
  .empty-state p { margin: 0; font-size: 13px; }

  .spinner {
    width: 32px;
    height: 32px;
    border: 3px solid #30363d;
    border-top-color: #388bfd;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin { to { transform: rotate(360deg); } }

  .zoom-controls {
    position: absolute;
    bottom: 16px;
    left: 16px;
    display: flex;
    flex-direction: column;
    gap: 2px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 4px;
  }

  .zoom-controls button {
    width: 32px;
    height: 32px;
    border: none;
    background: transparent;
    color: #8b949e;
    border-radius: 6px;
    cursor: pointer;
    font-size: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .zoom-controls button:hover { background: #30363d; color: #f0f6fc; }

  .node-tooltip {
    position: absolute;
    transform: translate(-50%, -100%);
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 10px 12px;
    pointer-events: none;
    z-index: 1000;
    box-shadow: 0 6px 20px rgba(0,0,0,0.4);
    min-width: 160px;
  }

  .tooltip-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
    padding-bottom: 6px;
    border-bottom: 1px solid #30363d;
  }

  .tooltip-name { font-weight: 600; color: #f0f6fc; font-size: 12px; }

  .tooltip-health {
    font-size: 9px;
    font-weight: 600;
    text-transform: uppercase;
    padding: 2px 6px;
    border-radius: 4px;
  }

  .health-healthy { background: rgba(16, 185, 129, 0.2); color: #10b981; }
  .health-degraded { background: rgba(245, 158, 11, 0.2); color: #f59e0b; }
  .health-critical { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
  .health-unknown { background: rgba(107, 114, 128, 0.2); color: #6b7280; }

  .tooltip-stats { display: flex; gap: 14px; }
  .stat { display: flex; flex-direction: column; }
  .stat-value { font-size: 14px; font-weight: 600; color: #f0f6fc; }
  .stat-value.error { color: #ef4444; }
  .stat-label { font-size: 9px; color: #8b949e; text-transform: uppercase; }

  /* Service Panel */
  .service-panel {
    width: 320px;
    background: #161b22;
    border-left: 1px solid #30363d;
    display: flex;
    flex-direction: column;
    animation: slideIn 0.2s ease-out;
  }

  @keyframes slideIn {
    from { transform: translateX(20px); opacity: 0; }
    to { transform: translateX(0); opacity: 1; }
  }

  .panel-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding: 16px;
    border-bottom: 1px solid #30363d;
    background: linear-gradient(180deg, #21262d 0%, #161b22 100%);
  }

  .service-info { display: flex; gap: 10px; align-items: center; }

  .service-icon-wrapper {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    background: #21262d;
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid #30363d;
  }

  .type-icon { width: 28px; height: 28px; border-radius: 4px; }

  .service-info h3 { margin: 0; font-size: 14px; font-weight: 600; color: #f0f6fc; }

  .service-meta { display: flex; gap: 6px; margin-top: 4px; }

  .type-badge {
    font-size: 10px;
    padding: 2px 6px;
    background: rgba(56, 139, 253, 0.15);
    color: #58a6ff;
    border-radius: 4px;
  }

  .health-badge {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    padding: 2px 6px;
    border-radius: 4px;
  }

  .close-btn {
    padding: 4px;
    border: none;
    background: transparent;
    color: #8b949e;
    cursor: pointer;
    border-radius: 4px;
  }

  .close-btn:hover { color: #f0f6fc; background: #30363d; }

  .loading-panel {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 40px;
  }

  .spinner-small {
    width: 20px;
    height: 20px;
    border: 2px solid #30363d;
    border-top-color: #388bfd;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .panel-content {
    flex: 1;
    overflow-y: auto;
    padding: 12px;
  }

  .stats-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 8px;
    margin-bottom: 12px;
  }

  .stat-card {
    padding: 10px;
    background: #21262d;
    border-radius: 8px;
    border: 1px solid #30363d;
  }

  .stat-card .stat-value {
    font-size: 18px;
    font-weight: 700;
    color: #f0f6fc;
    display: block;
  }

  .stat-card .stat-label {
    font-size: 10px;
    color: #8b949e;
  }

  .chart-section {
    margin-bottom: 12px;
    padding: 10px;
    background: #21262d;
    border-radius: 8px;
    border: 1px solid #30363d;
  }

  .chart-section h4 {
    margin: 0 0 8px;
    font-size: 11px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
  }

  .errors-section h4 {
    margin: 0 0 8px;
    font-size: 11px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
  }

  .error-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
    max-height: 180px;
    overflow-y: auto;
  }

  .error-item {
    padding: 8px;
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: 6px;
  }

  .error-time { font-size: 10px; color: #8b949e; margin-bottom: 2px; }
  .error-msg {
    font-size: 11px;
    color: #f0f6fc;
    line-height: 1.3;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  /* Legend */
  .legend {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 10px 16px;
    border-top: 1px solid #30363d;
    background: #161b22;
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
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

  .legend-divider { width: 1px; height: 16px; background: #30363d; }

  .legend-line { width: 20px; height: 2px; border-radius: 1px; }
  .legend-line.normal { background: #4b5563; }
  .legend-line.error { background: #ef4444; }
</style>
