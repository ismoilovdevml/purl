<script>
  import { onMount, onDestroy } from 'svelte';
  import { writable } from 'svelte/store';

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
  const API_BASE = '/api';

  // Color palette for services
  const serviceColors = [
    '#3b82f6', '#8b5cf6', '#06b6d4', '#10b981', '#f59e0b',
    '#ef4444', '#ec4899', '#6366f1', '#14b8a6', '#f97316'
  ];

  const colorMap = {};
  let colorIndex = 0;

  function getServiceColor(service) {
    if (!colorMap[service]) {
      colorMap[service] = serviceColors[colorIndex % serviceColors.length];
      colorIndex++;
    }
    return colorMap[service];
  }

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

  // Fetch service details
  async function fetchServiceDetails(name) {
    detailsLoading = true;
    try {
      const response = await fetch(`${API_BASE}/services/${encodeURIComponent(name)}`);
      if (response.ok) {
        serviceDetails = await response.json();
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
            'background-color': 'data(color)',
            'background-opacity': 0.9,
            'label': 'data(label)',
            'text-valign': 'bottom',
            'text-halign': 'center',
            'font-size': '12px',
            'font-weight': '500',
            'color': '#e2e8f0',
            'text-margin-y': 10,
            'text-outline-color': '#0d1117',
            'text-outline-width': 2,
            'width': 50,
            'height': 50,
            'border-width': 3,
            'border-color': 'data(borderColor)',
            'border-opacity': 1,
            'shadow-blur': 15,
            'shadow-color': 'data(color)',
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
            'shadow-blur': 25,
            'shadow-opacity': 0.6,
            'z-index': 999,
          }
        },
        {
          selector: 'node:selected',
          style: {
            'border-color': '#fff',
            'border-width': 4,
            'shadow-blur': 30,
            'shadow-opacity': 0.8,
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
            'arrow-scale': 1.2,
            'opacity': 0.7,
          }
        },
        {
          selector: 'edge.error',
          style: {
            'line-color': '#ef4444',
            'target-arrow-color': '#ef4444',
            'line-style': 'solid',
          }
        },
        {
          selector: 'edge:hover',
          style: {
            'width': 4,
            'opacity': 1,
            'z-index': 999,
          }
        },
        {
          selector: 'edge:selected',
          style: {
            'line-color': '#3b82f6',
            'target-arrow-color': '#3b82f6',
            'width': 4,
            'opacity': 1,
          }
        }
      ],
      layout: {
        name: 'cose',
        idealEdgeLength: 180,
        nodeRepulsion: 500000,
        animate: true,
        animationDuration: 800,
        animationEasing: 'ease-out-cubic',
      },
      minZoom: 0.2,
      maxZoom: 4,
      wheelSensitivity: 0.3,
    });

    // Node hover - show tooltip
    cy.on('mouseover', 'node', (event) => {
      const node = event.target;
      const pos = node.renderedPosition();
      hoveredNode = {
        id: node.id(),
        label: node.data('label'),
        logCount: node.data('logCount'),
        errorCount: node.data('errorCount'),
        health: node.data('health'),
      };
      tooltipPosition = { x: pos.x, y: pos.y - 40 };
    });

    cy.on('mouseout', 'node', () => {
      hoveredNode = null;
    });

    // Node click handler
    cy.on('tap', 'node', async (event) => {
      const node = event.target;
      const serviceId = node.id();
      selectedService.set(serviceId);
      await fetchServiceDetails(serviceId);
    });

    // Background click to deselect
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

    // Add nodes
    const nodes = (data.nodes || []).map(n => {
      const health = getHealthStatus(n.data.error_count, n.data.log_count);
      const baseColor = getServiceColor(n.data.id);
      return {
        data: {
          id: n.data.id,
          label: n.data.label || n.data.id,
          color: health.status === 'critical' ? '#ef4444' :
                 health.status === 'degraded' ? '#f59e0b' : baseColor,
          borderColor: health.color,
          logCount: n.data.log_count || 0,
          errorCount: n.data.error_count || 0,
          health: health.status,
        }
      };
    });

    // Add edges
    const edges = (data.edges || []).map(e => {
      const hasErrors = e.data.error_count > 0;
      return {
        data: {
          id: e.data.id,
          source: e.data.source,
          target: e.data.target,
          weight: Math.min(Math.log(e.data.call_count + 1) * 0.8 + 1.5, 6),
          callCount: e.data.call_count || 0,
          errorCount: e.data.error_count || 0,
          avgDuration: e.data.avg_duration_ms || 0,
        },
        classes: hasErrors ? 'error' : ''
      };
    });

    cy.add([...nodes, ...edges]);

    // Run layout
    cy.layout({
      name: 'cose',
      idealEdgeLength: 180,
      nodeRepulsion: 500000,
      animate: true,
      animationDuration: 800,
      animationEasing: 'ease-out-cubic',
    }).run();

    setTimeout(() => cy.fit(undefined, 60), 900);
  }

  // Zoom controls
  function zoomIn() {
    if (cy) cy.zoom(cy.zoom() * 1.3);
  }

  function zoomOut() {
    if (cy) cy.zoom(cy.zoom() / 1.3);
  }

  function fitGraph() {
    if (cy) cy.fit(undefined, 60);
  }

  function centerGraph() {
    if (cy) cy.center();
  }

  // Format number
  function formatNumber(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return n?.toString() || '0';
  }

  // Format error rate
  function formatErrorRate(errors, total) {
    if (!total) return '0%';
    return ((errors / total) * 100).toFixed(1) + '%';
  }

  let selectedRange = '1h';

  function handleRangeChange(range) {
    selectedRange = range;
    fetchServices(range);
    fetchDependencies(range);
  }

  onMount(async () => {
    await new Promise(resolve => setTimeout(resolve, 100));
    await initCytoscape();
    await fetchServices();
    await fetchDependencies();
  });

  // Re-render when dependencies change
  $: if (cy && $dependencies.nodes && $dependencies.nodes.length > 0) {
    renderGraph($dependencies);
  }

  onDestroy(() => {
    if (cy) {
      cy.destroy();
    }
  });
</script>

<div class="service-map-container">
  <div class="service-map-header">
    <div class="header-left">
      <h2>Service Map</h2>
      <span class="subtitle">{$dependencies.nodes?.length || 0} services • {$dependencies.edges?.length || 0} connections</span>
    </div>
    <div class="controls">
      <div class="time-range">
        {#each ['15m', '1h', '6h', '24h'] as range}
          <button
            class:active={selectedRange === range}
            on:click={() => handleRangeChange(range)}
          >
            {range}
          </button>
        {/each}
      </div>
      <button class="refresh-btn" on:click={() => fetchDependencies(selectedRange)}>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M23 4v6h-6M1 20v-6h6M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/>
        </svg>
        Refresh
      </button>
    </div>
  </div>

  <div class="service-map-content">
    <div class="graph-wrapper">
      <div class="graph-container" bind:this={container}>
        {#if $loading}
          <div class="loading-overlay">
            <div class="spinner"></div>
            <span>Loading service map...</span>
          </div>
        {:else if !$dependencies.nodes || $dependencies.nodes.length === 0}
          <div class="empty-state">
            <svg width="80" height="80" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1">
              <circle cx="12" cy="12" r="3" />
              <circle cx="19" cy="5" r="2" />
              <circle cx="5" cy="5" r="2" />
              <circle cx="19" cy="19" r="2" />
              <circle cx="5" cy="19" r="2" />
              <path d="M12 9V6M12 15v3M9 12H6M15 12h3"/>
            </svg>
            <h3>No Services Found</h3>
            <p>Service dependencies will appear here once logs with trace data are ingested.</p>
          </div>
        {/if}
      </div>

      <!-- Zoom Controls -->
      <div class="zoom-controls">
        <button on:click={zoomIn} title="Zoom In">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35M11 8v6M8 11h6"/>
          </svg>
        </button>
        <button on:click={zoomOut} title="Zoom Out">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35M8 11h6"/>
          </svg>
        </button>
        <button on:click={fitGraph} title="Fit to View">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/>
          </svg>
        </button>
        <button on:click={centerGraph} title="Center">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="3"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4"/>
          </svg>
        </button>
      </div>

      <!-- Node Tooltip -->
      {#if hoveredNode}
        <div class="node-tooltip" style="left: {tooltipPosition.x}px; top: {tooltipPosition.y}px;">
          <div class="tooltip-header">
            <span class="tooltip-name">{hoveredNode.label}</span>
            <span class="tooltip-health health-{hoveredNode.health}">{hoveredNode.health}</span>
          </div>
          <div class="tooltip-stats">
            <div class="stat">
              <span class="stat-value">{formatNumber(hoveredNode.logCount)}</span>
              <span class="stat-label">logs</span>
            </div>
            <div class="stat">
              <span class="stat-value error">{formatNumber(hoveredNode.errorCount)}</span>
              <span class="stat-label">errors</span>
            </div>
            <div class="stat">
              <span class="stat-value">{formatErrorRate(hoveredNode.errorCount, hoveredNode.logCount)}</span>
              <span class="stat-label">error rate</span>
            </div>
          </div>
        </div>
      {/if}
    </div>

    <!-- Service Details Panel -->
    {#if $selectedService && serviceDetails}
      <div class="service-details">
        <div class="details-header">
          <div class="service-info">
            <div class="service-icon" style="background: {getServiceColor($selectedService)}">
              {$selectedService.charAt(0).toUpperCase()}
            </div>
            <div>
              <h3>{$selectedService}</h3>
              {#if serviceDetails.metrics}
                {@const health = getHealthStatus(serviceDetails.metrics.error_count, serviceDetails.metrics.total_logs)}
                <span class="health-badge health-{health.status}">{health.status}</span>
              {/if}
            </div>
          </div>
          <button class="close-btn" on:click={() => { selectedService.set(null); serviceDetails = null; }} aria-label="Close">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M18 6L6 18M6 6l12 12"/>
            </svg>
          </button>
        </div>

        {#if detailsLoading}
          <div class="loading-details">
            <div class="spinner-small"></div>
            <span>Loading...</span>
          </div>
        {:else if serviceDetails.metrics}
          <div class="metrics-section">
            <h4>Metrics</h4>
            <div class="metrics-grid">
              <div class="metric-card">
                <div class="metric-icon logs">
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
                    <path d="M14 2v6h6M16 13H8M16 17H8M10 9H8"/>
                  </svg>
                </div>
                <div class="metric-content">
                  <span class="metric-value">{formatNumber(serviceDetails.metrics.total_logs || 0)}</span>
                  <span class="metric-label">Total Logs</span>
                </div>
              </div>
              <div class="metric-card">
                <div class="metric-icon errors">
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <circle cx="12" cy="12" r="10"/><path d="M12 8v4M12 16h.01"/>
                  </svg>
                </div>
                <div class="metric-content">
                  <span class="metric-value error">{formatNumber(serviceDetails.metrics.error_count || 0)}</span>
                  <span class="metric-label">Errors</span>
                </div>
              </div>
              <div class="metric-card">
                <div class="metric-icon warns">
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
                    <path d="M12 9v4M12 17h.01"/>
                  </svg>
                </div>
                <div class="metric-content">
                  <span class="metric-value warn">{formatNumber(serviceDetails.metrics.warn_count || 0)}</span>
                  <span class="metric-label">Warnings</span>
                </div>
              </div>
              <div class="metric-card">
                <div class="metric-icon traces">
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
                  </svg>
                </div>
                <div class="metric-content">
                  <span class="metric-value">{formatNumber(serviceDetails.metrics.unique_traces || 0)}</span>
                  <span class="metric-label">Traces</span>
                </div>
              </div>
            </div>
          </div>

          {#if serviceDetails.recent_errors && serviceDetails.recent_errors.length > 0}
            <div class="errors-section">
              <h4>Recent Errors ({serviceDetails.recent_errors.length})</h4>
              <div class="error-list">
                {#each serviceDetails.recent_errors as error}
                  <div class="error-item">
                    <div class="error-time">{new Date(error.timestamp).toLocaleTimeString()}</div>
                    <div class="error-msg">{error.message}</div>
                    {#if error.trace_id}
                      <div class="error-trace">
                        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                          <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
                        </svg>
                        {error.trace_id.substring(0, 16)}...
                      </div>
                    {/if}
                  </div>
                {/each}
              </div>
            </div>
          {/if}
        {/if}
      </div>
    {/if}
  </div>

  <div class="legend">
    <div class="legend-item">
      <span class="legend-dot healthy"></span>
      <span>Healthy (&lt;5%)</span>
    </div>
    <div class="legend-item">
      <span class="legend-dot degraded"></span>
      <span>Degraded (5-10%)</span>
    </div>
    <div class="legend-item">
      <span class="legend-dot critical"></span>
      <span>Critical (&gt;10%)</span>
    </div>
    <div class="legend-divider"></div>
    <div class="legend-item">
      <span class="legend-line normal"></span>
      <span>Normal</span>
    </div>
    <div class="legend-item">
      <span class="legend-line error"></span>
      <span>Has Errors</span>
    </div>
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
    padding: 16px 20px;
    border-bottom: 1px solid #30363d;
    background: rgba(22, 27, 34, 0.8);
    backdrop-filter: blur(10px);
  }

  .header-left h2 {
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    color: #f0f6fc;
  }

  .subtitle {
    font-size: 12px;
    color: #8b949e;
    margin-top: 2px;
    display: block;
  }

  .controls {
    display: flex;
    gap: 12px;
    align-items: center;
  }

  .time-range {
    display: flex;
    gap: 2px;
    background: #21262d;
    padding: 3px;
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
    transition: all 0.2s;
  }

  .time-range button:hover {
    color: #c9d1d9;
    background: rgba(255,255,255,0.05);
  }

  .time-range button.active {
    background: #388bfd;
    color: #fff;
    box-shadow: 0 2px 8px rgba(56, 139, 253, 0.3);
  }

  .refresh-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 14px;
    border: 1px solid #30363d;
    background: #21262d;
    color: #c9d1d9;
    border-radius: 8px;
    cursor: pointer;
    font-size: 13px;
    font-weight: 500;
    transition: all 0.2s;
  }

  .refresh-btn:hover {
    background: #30363d;
    border-color: #8b949e;
  }

  .service-map-content {
    flex: 1;
    display: flex;
    position: relative;
    overflow: hidden;
  }

  .graph-wrapper {
    flex: 1;
    position: relative;
  }

  .graph-container {
    width: 100%;
    height: 100%;
    min-height: 500px;
  }

  .loading-overlay {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    background: rgba(13, 17, 23, 0.9);
    backdrop-filter: blur(4px);
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

  .empty-state svg {
    opacity: 0.3;
    margin-bottom: 16px;
  }

  .empty-state h3 {
    margin: 0 0 8px 0;
    font-size: 18px;
    color: #c9d1d9;
  }

  .empty-state p {
    margin: 0;
    font-size: 14px;
    max-width: 300px;
  }

  .spinner {
    width: 40px;
    height: 40px;
    border: 3px solid #30363d;
    border-top-color: #388bfd;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* Zoom Controls */
  .zoom-controls {
    position: absolute;
    bottom: 20px;
    left: 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 10px;
    padding: 6px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
  }

  .zoom-controls button {
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
    transition: all 0.2s;
  }

  .zoom-controls button:hover {
    background: #30363d;
    color: #f0f6fc;
  }

  /* Node Tooltip */
  .node-tooltip {
    position: absolute;
    transform: translate(-50%, -100%);
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 10px;
    padding: 12px 14px;
    pointer-events: none;
    z-index: 1000;
    box-shadow: 0 8px 24px rgba(0,0,0,0.4);
    min-width: 180px;
  }

  .tooltip-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 10px;
    padding-bottom: 8px;
    border-bottom: 1px solid #30363d;
  }

  .tooltip-name {
    font-weight: 600;
    color: #f0f6fc;
    font-size: 13px;
  }

  .tooltip-health {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    padding: 3px 8px;
    border-radius: 4px;
  }

  .health-healthy { background: rgba(16, 185, 129, 0.2); color: #10b981; }
  .health-degraded { background: rgba(245, 158, 11, 0.2); color: #f59e0b; }
  .health-critical { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
  .health-unknown { background: rgba(107, 114, 128, 0.2); color: #6b7280; }

  .tooltip-stats {
    display: flex;
    gap: 16px;
  }

  .stat {
    display: flex;
    flex-direction: column;
  }

  .stat-value {
    font-size: 15px;
    font-weight: 600;
    color: #f0f6fc;
  }

  .stat-value.error { color: #ef4444; }

  .stat-label {
    font-size: 10px;
    color: #8b949e;
    text-transform: uppercase;
  }

  /* Service Details Panel */
  .service-details {
    width: 340px;
    background: #161b22;
    border-left: 1px solid #30363d;
    overflow-y: auto;
    animation: slideIn 0.2s ease-out;
  }

  @keyframes slideIn {
    from { transform: translateX(20px); opacity: 0; }
    to { transform: translateX(0); opacity: 1; }
  }

  .details-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding: 20px;
    border-bottom: 1px solid #30363d;
    background: linear-gradient(180deg, #21262d 0%, #161b22 100%);
  }

  .service-info {
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
    font-size: 18px;
    font-weight: 700;
    color: #fff;
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
  }

  .service-info h3 {
    margin: 0 0 4px 0;
    font-size: 16px;
    font-weight: 600;
    color: #f0f6fc;
  }

  .health-badge {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    padding: 3px 8px;
    border-radius: 4px;
  }

  .close-btn {
    padding: 6px;
    border: none;
    background: transparent;
    color: #8b949e;
    cursor: pointer;
    border-radius: 6px;
    transition: all 0.2s;
  }

  .close-btn:hover {
    color: #f0f6fc;
    background: #30363d;
  }

  .loading-details {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 40px;
    color: #8b949e;
  }

  .spinner-small {
    width: 20px;
    height: 20px;
    border: 2px solid #30363d;
    border-top-color: #388bfd;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .metrics-section, .errors-section {
    padding: 20px;
  }

  .metrics-section h4, .errors-section h4 {
    margin: 0 0 14px 0;
    font-size: 12px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .metrics-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
  }

  .metric-card {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 14px;
    background: #21262d;
    border-radius: 10px;
    border: 1px solid #30363d;
  }

  .metric-icon {
    width: 38px;
    height: 38px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .metric-icon.logs { background: rgba(56, 139, 253, 0.15); color: #388bfd; }
  .metric-icon.errors { background: rgba(239, 68, 68, 0.15); color: #ef4444; }
  .metric-icon.warns { background: rgba(245, 158, 11, 0.15); color: #f59e0b; }
  .metric-icon.traces { background: rgba(139, 92, 246, 0.15); color: #8b5cf6; }

  .metric-content {
    display: flex;
    flex-direction: column;
  }

  .metric-value {
    font-size: 18px;
    font-weight: 700;
    color: #f0f6fc;
  }

  .metric-value.error { color: #ef4444; }
  .metric-value.warn { color: #f59e0b; }

  .metric-label {
    font-size: 11px;
    color: #8b949e;
  }

  .errors-section {
    border-top: 1px solid #30363d;
  }

  .error-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
    max-height: 250px;
    overflow-y: auto;
  }

  .error-item {
    padding: 12px;
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: 8px;
  }

  .error-time {
    font-size: 10px;
    color: #8b949e;
    margin-bottom: 4px;
  }

  .error-msg {
    font-size: 12px;
    color: #f0f6fc;
    line-height: 1.4;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .error-trace {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-top: 6px;
    font-size: 10px;
    color: #8b5cf6;
    font-family: monospace;
  }

  /* Legend */
  .legend {
    display: flex;
    align-items: center;
    gap: 20px;
    padding: 12px 20px;
    border-top: 1px solid #30363d;
    background: #161b22;
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: #8b949e;
  }

  .legend-dot {
    width: 12px;
    height: 12px;
    border-radius: 50%;
    box-shadow: 0 0 8px currentColor;
  }

  .legend-dot.healthy { background: #10b981; color: #10b981; }
  .legend-dot.degraded { background: #f59e0b; color: #f59e0b; }
  .legend-dot.critical { background: #ef4444; color: #ef4444; }

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

  .legend-line.normal { background: #4b5563; }
  .legend-line.error { background: #ef4444; }
</style>
