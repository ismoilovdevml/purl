<script>
  import { onMount, onDestroy } from 'svelte';
  import { formatTimestamp, formatFullTimestamp, getLevelColor, query, fetchLogContext, filterByTrace, filterByRequest } from '../stores/logs.js';

  export let logs = [];

  // Context state
  let contextData = {};
  let contextLoading = {};

  // Current search query for highlighting
  let searchQuery = '';
  const unsubscribeQuery = query.subscribe(v => searchQuery = v);

  // Cleanup subscriptions on destroy
  onDestroy(() => {
    unsubscribeQuery();
  });

  // Escape HTML to prevent XSS
  function escapeHtml(text) {
    if (!text) return '';
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  // Highlight matching text in a string (XSS-safe)
  function highlightText(text, query) {
    if (!text) return '';
    // First escape HTML in the text
    let safeText = escapeHtml(text);

    // Then highlight search query if present
    if (query) {
      const safeQuery = escapeHtml(query);
      const escaped = safeQuery.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const regex = new RegExp(`(${escaped})`, 'gi');
      safeText = safeText.replace(regex, '<mark class="search-highlight">$1</mark>');
    }

    return safeText;
  }

  let selectedLog = null;
  let showColumnMenu = false;
  let columnSearch = '';
  let columnMenuRef = null;

  // Close column menu when clicking outside
  function handleClickOutside(event) {
    if (showColumnMenu && columnMenuRef && !columnMenuRef.contains(event.target)) {
      showColumnMenu = false;
      columnSearch = '';
    }
  }

  // Column groups for organization
  const columnGroups = {
    core: { label: 'Core Fields', icon: 'M3 3h18v18H3V3zm2 2v14h14V5H5z' },
    kubernetes: { label: 'Kubernetes', icon: 'M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5' },
    tracing: { label: 'Tracing', icon: 'M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z' }
  };

  // Presets for quick configuration
  const presets = [
    { id: 'default', name: 'Default', columns: ['time', 'level', 'service', 'message'] },
    { id: 'minimal', name: 'Minimal', columns: ['time', 'level', 'message'] },
    { id: 'k8s', name: 'Kubernetes', columns: ['time', 'level', 'namespace', 'pod', 'message'] },
    { id: 'debug', name: 'Debug', columns: ['time', 'level', 'service', 'host', 'message'] },
    { id: 'all', name: 'All Fields', columns: ['time', 'level', 'service', 'host', 'namespace', 'pod', 'node', 'message'] }
  ];

  // Column configuration with resizable widths and groups
  let columns = [
    { id: 'time', label: 'Time', visible: true, width: 90, minWidth: 60, group: 'core', pinned: false },
    { id: 'level', label: 'Level', visible: true, width: 100, minWidth: 60, group: 'core', pinned: false },
    { id: 'service', label: 'Service', visible: true, width: 150, minWidth: 80, group: 'core', pinned: false },
    { id: 'host', label: 'Host', visible: false, width: 120, minWidth: 80, group: 'core', pinned: false },
    { id: 'namespace', label: 'Namespace', visible: false, width: 120, minWidth: 80, meta: true, group: 'kubernetes', pinned: false },
    { id: 'pod', label: 'Pod', visible: false, width: 180, minWidth: 100, meta: true, group: 'kubernetes', pinned: false },
    { id: 'node', label: 'Node', visible: false, width: 150, minWidth: 100, meta: true, group: 'kubernetes', pinned: false },
    { id: 'message', label: 'Message', visible: true, width: null, minWidth: 200, group: 'core', pinned: false }
  ];

  // Drag and drop state
  let draggedColumn = null;
  let dragOverColumn = null;

  // Helper to get meta field value
  function getMetaField(log, field) {
    if (!log.meta) return '';
    try {
      const meta = typeof log.meta === 'string' ? JSON.parse(log.meta) : log.meta;
      return meta[field] || '';
    } catch {
      return '';
    }
  }

  // Resize state
  let resizing = null;
  let startX = 0;
  let startWidth = 0;

  onMount(() => {
    const saved = localStorage.getItem('purl_column_config');
    if (saved) {
      try {
        const parsed = JSON.parse(saved);
        columns = columns.map(col => ({
          ...col,
          ...parsed.find(p => p.id === col.id)
        }));
      } catch {
        // Ignore parse errors
      }
    }
  });

  function saveColumnConfig() {
    localStorage.setItem('purl_column_config', JSON.stringify(
      columns.map(c => ({ id: c.id, visible: c.visible, width: c.width }))
    ));
  }

  function selectLog(log) {
    selectedLog = selectedLog?.id === log.id ? null : log;
  }

  // Copy feedback state
  let copiedField = null;
  let copiedTimeout = null;

  function copyToClipboard(text, fieldId = null) {
    navigator.clipboard.writeText(text);

    // Show "Copied!" feedback
    if (copiedTimeout) clearTimeout(copiedTimeout);
    copiedField = fieldId || text;
    copiedTimeout = setTimeout(() => {
      copiedField = null;
    }, 700);
  }

  async function loadContext(logId) {
    if (contextData[logId]) {
      // Toggle off if already loaded
      delete contextData[logId];
      contextData = contextData;
      return;
    }

    contextLoading[logId] = true;
    contextLoading = contextLoading;

    const data = await fetchLogContext(logId, 50, 50);

    contextLoading[logId] = false;
    contextLoading = contextLoading;

    if (data) {
      contextData[logId] = data;
      contextData = contextData;
    }
  }

  function closeContext(logId) {
    delete contextData[logId];
    contextData = contextData;
  }

  function toggleColumn(colId) {
    // Create new array to trigger Svelte reactivity
    columns = columns.map(c =>
      c.id === colId ? { ...c, visible: !c.visible } : c
    );
    saveColumnConfig();
  }

  function startResize(event, colId) {
    event.preventDefault();
    const col = columns.find(c => c.id === colId);
    if (!col || col.id === 'message') return;

    resizing = colId;
    startX = event.clientX;
    startWidth = col.width;

    document.addEventListener('mousemove', handleResize);
    document.addEventListener('mouseup', stopResize);
  }

  function handleResize(event) {
    if (!resizing) return;
    const col = columns.find(c => c.id === resizing);
    if (!col) return;

    const delta = event.clientX - startX;
    col.width = Math.max(col.minWidth, startWidth + delta);
    columns = columns;
  }

  function stopResize() {
    if (resizing) {
      saveColumnConfig();
    }
    resizing = null;
    document.removeEventListener('mousemove', handleResize);
    document.removeEventListener('mouseup', stopResize);
  }

  function resetColumns() {
    columns = [
      { id: 'time', label: 'Time', visible: true, width: 90, minWidth: 60, group: 'core', pinned: false },
      { id: 'level', label: 'Level', visible: true, width: 100, minWidth: 60, group: 'core', pinned: false },
      { id: 'service', label: 'Service', visible: true, width: 150, minWidth: 80, group: 'core', pinned: false },
      { id: 'host', label: 'Host', visible: false, width: 120, minWidth: 80, group: 'core', pinned: false },
      { id: 'namespace', label: 'Namespace', visible: false, width: 120, minWidth: 80, meta: true, group: 'kubernetes', pinned: false },
      { id: 'pod', label: 'Pod', visible: false, width: 180, minWidth: 100, meta: true, group: 'kubernetes', pinned: false },
      { id: 'node', label: 'Node', visible: false, width: 150, minWidth: 100, meta: true, group: 'kubernetes', pinned: false },
      { id: 'message', label: 'Message', visible: true, width: null, minWidth: 200, group: 'core', pinned: false }
    ];
    saveColumnConfig();
  }

  // Apply preset configuration
  function applyPreset(preset) {
    columns = columns.map(col => ({
      ...col,
      visible: preset.columns.includes(col.id)
    }));
    // Reorder to match preset order
    const orderedColumns = [];
    preset.columns.forEach(id => {
      const col = columns.find(c => c.id === id);
      if (col) orderedColumns.push(col);
    });
    // Add remaining columns at the end
    columns.forEach(col => {
      if (!orderedColumns.includes(col)) {
        orderedColumns.push(col);
      }
    });
    columns = orderedColumns;
    saveColumnConfig();
  }

  // Get current preset name if matches
  function getCurrentPreset() {
    const visibleIds = columns.filter(c => c.visible).map(c => c.id);
    return presets.find(p =>
      p.columns.length === visibleIds.length &&
      p.columns.every((id, i) => id === visibleIds[i])
    )?.name || null;
  }

  // Drag and drop handlers
  function handleDragStart(event, colId) {
    draggedColumn = colId;
    event.dataTransfer.effectAllowed = 'move';
  }

  function handleDragOver(event, colId) {
    event.preventDefault();
    if (draggedColumn && draggedColumn !== colId) {
      dragOverColumn = colId;
    }
  }

  function handleDragLeave() {
    dragOverColumn = null;
  }

  function handleDrop(event, targetId) {
    event.preventDefault();
    if (draggedColumn && draggedColumn !== targetId) {
      const dragIdx = columns.findIndex(c => c.id === draggedColumn);
      const targetIdx = columns.findIndex(c => c.id === targetId);

      if (dragIdx !== -1 && targetIdx !== -1) {
        const newColumns = [...columns];
        const [removed] = newColumns.splice(dragIdx, 1);
        newColumns.splice(targetIdx, 0, removed);
        columns = newColumns;
        saveColumnConfig();
      }
    }
    draggedColumn = null;
    dragOverColumn = null;
  }

  function handleDragEnd() {
    draggedColumn = null;
    dragOverColumn = null;
  }

  // Toggle pin column
  function togglePin(colId) {
    columns = columns.map(c =>
      c.id === colId ? { ...c, pinned: !c.pinned } : c
    );
    saveColumnConfig();
  }

  // Filter columns by search
  $: filteredColumns = columnSearch
    ? columns.filter(c => c.label.toLowerCase().includes(columnSearch.toLowerCase()))
    : columns;

  // Group columns for display
  $: groupedColumns = Object.keys(columnGroups).reduce((acc, group) => {
    acc[group] = filteredColumns.filter(c => c.group === group);
    return acc;
  }, {});

  $: visibleColumns = columns.filter(c => c.visible);
  $: pinnedColumns = visibleColumns.filter(c => c.pinned);
  $: unpinnedColumns = visibleColumns.filter(c => !c.pinned);
  $: orderedVisibleColumns = [...pinnedColumns, ...unpinnedColumns];
  $: colspanCount = visibleColumns.length;
  $: currentPreset = getCurrentPreset();
</script>

<svelte:window on:click={handleClickOutside} />

<div class="log-table-container">
  <!-- Column Settings Menu -->
  <div class="table-toolbar">
    <div class="column-menu-container" bind:this={columnMenuRef}>
      <button class="toolbar-btn" on:click|stopPropagation={() => showColumnMenu = !showColumnMenu} title="Configure columns">
        <svg width="14" height="14" viewBox="0 0 16 16">
          <path fill="currentColor" d="M1.5 3a.5.5 0 0 0 0 1h13a.5.5 0 0 0 0-1h-13zM1 7.5a.5.5 0 0 1 .5-.5h13a.5.5 0 0 1 0 1h-13a.5.5 0 0 1-.5-.5zm.5 3.5a.5.5 0 0 0 0 1h8a.5.5 0 0 0 0-1h-8z"/>
        </svg>
        <span class="toolbar-btn-text">Columns</span>
        {#if currentPreset}
          <span class="preset-badge">{currentPreset}</span>
        {/if}
      </button>
      {#if showColumnMenu}
        <!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
        <div class="column-menu" on:click|stopPropagation>
          <!-- Search -->
          <div class="column-menu-search">
            <svg width="14" height="14" viewBox="0 0 16 16">
              <path fill="currentColor" d="M11.742 10.344a6.5 6.5 0 1 0-1.397 1.398h-.001c.03.04.062.078.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1.007 1.007 0 0 0-.115-.1zM12 6.5a5.5 5.5 0 1 1-11 0 5.5 5.5 0 0 1 11 0z"/>
            </svg>
            <input
              type="text"
              placeholder="Search columns..."
              bind:value={columnSearch}
              class="column-search-input"
            />
          </div>

          <!-- Presets -->
          <div class="column-presets">
            <span class="presets-label">Quick Views</span>
            <div class="preset-chips">
              {#each presets as preset}
                <button
                  class="preset-chip"
                  class:active={currentPreset === preset.name}
                  on:click={() => applyPreset(preset)}
                  title={preset.columns.join(', ')}
                >
                  {preset.name}
                </button>
              {/each}
            </div>
          </div>

          <div class="column-menu-divider"></div>

          <!-- Grouped columns -->
          <div class="column-groups">
            {#each Object.entries(groupedColumns) as [groupKey, groupCols]}
              {#if groupCols.length > 0}
                <div class="column-group">
                  <div class="group-header">
                    <svg width="12" height="12" viewBox="0 0 24 24">
                      <path fill="currentColor" d={columnGroups[groupKey].icon}/>
                    </svg>
                    <span>{columnGroups[groupKey].label}</span>
                    <span class="group-count">{groupCols.filter(c => c.visible).length}/{groupCols.length}</span>
                  </div>
                  <div class="group-columns">
                    {#each groupCols as col (col.id)}
                      <!-- svelte-ignore a11y-no-static-element-interactions -->
                      <div
                        class="column-item"
                        class:visible={col.visible}
                        class:dragging={draggedColumn === col.id}
                        class:drag-over={dragOverColumn === col.id}
                        draggable="true"
                        on:dragstart={(e) => handleDragStart(e, col.id)}
                        on:dragover={(e) => handleDragOver(e, col.id)}
                        on:dragleave={handleDragLeave}
                        on:drop={(e) => handleDrop(e, col.id)}
                        on:dragend={handleDragEnd}
                      >
                        <div class="drag-handle" title="Drag to reorder">
                          <svg width="10" height="10" viewBox="0 0 16 16">
                            <path fill="currentColor" d="M2 4a1 1 0 1 1 0-2 1 1 0 0 1 0 2zm0 5a1 1 0 1 1 0-2 1 1 0 0 1 0 2zm0 5a1 1 0 1 1 0-2 1 1 0 0 1 0 2zm6-10a1 1 0 1 1 0-2 1 1 0 0 1 0 2zm0 5a1 1 0 1 1 0-2 1 1 0 0 1 0 2zm0 5a1 1 0 1 1 0-2 1 1 0 0 1 0 2z"/>
                          </svg>
                        </div>
                        <label class="column-checkbox">
                          <input
                            type="checkbox"
                            checked={col.visible}
                            on:change={() => toggleColumn(col.id)}
                          />
                          <span class="checkmark"></span>
                        </label>
                        <span class="column-label">{col.label}</span>
                        {#if col.visible}
                          <button
                            class="pin-btn"
                            class:pinned={col.pinned}
                            on:click|stopPropagation={() => togglePin(col.id)}
                            title={col.pinned ? 'Unpin column' : 'Pin column to left'}
                          >
                            <svg width="12" height="12" viewBox="0 0 16 16">
                              <path fill="currentColor" d={col.pinned
                                ? "M9.828.722a.5.5 0 0 1 .354.146l4.95 4.95a.5.5 0 0 1 0 .707c-.48.48-1.072.588-1.503.588-.177 0-.335-.018-.46-.039l-3.134 3.134a5.927 5.927 0 0 1 .16 1.013c.046.702-.032 1.687-.72 2.375a.5.5 0 0 1-.707 0l-2.829-2.828-3.182 3.182c-.195.195-1.219.902-1.414.707-.195-.195.512-1.22.707-1.414l3.182-3.182-2.828-2.829a.5.5 0 0 1 0-.707c.688-.688 1.673-.767 2.375-.72a5.922 5.922 0 0 1 1.013.16l3.134-3.133a2.772 2.772 0 0 1-.04-.461c0-.43.108-1.022.589-1.503a.5.5 0 0 1 .353-.146z"
                                : "M9.828.722a.5.5 0 0 1 .354.146l4.95 4.95a.5.5 0 0 1 0 .707c-.48.48-1.072.588-1.503.588-.177 0-.335-.018-.46-.039l-3.134 3.134a5.927 5.927 0 0 1 .16 1.013c.046.702-.032 1.687-.72 2.375a.5.5 0 0 1-.707 0l-2.829-2.828-3.182 3.182c-.195.195-1.219.902-1.414.707-.195-.195.512-1.22.707-1.414l3.182-3.182-2.828-2.829a.5.5 0 0 1 0-.707c.688-.688 1.673-.767 2.375-.72a5.922 5.922 0 0 1 1.013.16l3.134-3.133a2.772 2.772 0 0 1-.04-.461c0-.43.108-1.022.589-1.503a.5.5 0 0 1 .353-.146zm.122 2.112v-.002.002zm0-.002v.002a.5.5 0 0 1-.122.51L6.293 6.878a.5.5 0 0 1-.511.12H5.78l-.014-.004a4.507 4.507 0 0 0-.288-.076 4.922 4.922 0 0 0-.765-.116c-.422-.028-.836.008-1.175.15l5.51 5.509c.141-.34.177-.753.149-1.175a4.924 4.924 0 0 0-.192-1.054l-.004-.013v-.001a.5.5 0 0 1 .12-.512l3.536-3.535a.5.5 0 0 1 .532-.115l.096.022c.087.017.208.034.344.034.114 0 .23-.011.343-.04L9.927 2.028c-.029.113-.04.229-.04.343a1.779 1.779 0 0 0 .062.46z"
                              }/>
                            </svg>
                          </button>
                        {/if}
                      </div>
                    {/each}
                  </div>
                </div>
              {/if}
            {/each}
          </div>

          <div class="column-menu-footer">
            <button class="reset-link" on:click={resetColumns}>
              <svg width="12" height="12" viewBox="0 0 16 16">
                <path fill="currentColor" d="M8 3a5 5 0 1 0 4.546 2.914.5.5 0 0 1 .908-.417A6 6 0 1 1 8 2v1z"/>
                <path fill="currentColor" d="M8 4.466V.534a.25.25 0 0 1 .41-.192l2.36 1.966c.12.1.12.284 0 .384L8.41 4.658A.25.25 0 0 1 8 4.466z"/>
              </svg>
              Reset to Default
            </button>
            <span class="visible-count">{visibleColumns.length} visible</span>
          </div>
        </div>
      {/if}
    </div>
    <span class="toolbar-info">{logs.length} logs</span>
  </div>

  {#if logs.length === 0}
    <div class="empty-state">
      <svg width="48" height="48" viewBox="0 0 48 48">
        <path fill="currentColor" opacity="0.3" d="M24 4C12.954 4 4 12.954 4 24s8.954 20 20 20 20-8.954 20-20S35.046 4 24 4Zm0 36c-8.837 0-16-7.163-16-16S15.163 8 24 8s16 7.163 16 16-7.163 16-16 16Z"/>
        <path fill="currentColor" d="M24 14a2 2 0 0 1 2 2v8a2 2 0 0 1-4 0v-8a2 2 0 0 1 2-2Zm0 16a2 2 0 1 1 0 4 2 2 0 0 1 0-4Z"/>
      </svg>
      <p>No logs found</p>
      <span>Try adjusting your search or time range</span>
    </div>
  {:else}
    <table class="log-table" class:resizing={resizing !== null}>
      <thead>
        <tr>
          {#each orderedVisibleColumns as col}
            <th
              style={col.width ? `width: ${col.width}px` : ''}
              class:pinned={col.pinned}
            >
              {#if col.pinned}
                <svg class="pin-icon" width="10" height="10" viewBox="0 0 16 16">
                  <path fill="currentColor" d="M9.828.722a.5.5 0 0 1 .354.146l4.95 4.95a.5.5 0 0 1 0 .707c-.48.48-1.072.588-1.503.588-.177 0-.335-.018-.46-.039l-3.134 3.134a5.927 5.927 0 0 1 .16 1.013c.046.702-.032 1.687-.72 2.375a.5.5 0 0 1-.707 0l-2.829-2.828-3.182 3.182c-.195.195-1.219.902-1.414.707-.195-.195.512-1.22.707-1.414l3.182-3.182-2.828-2.829a.5.5 0 0 1 0-.707c.688-.688 1.673-.767 2.375-.72a5.922 5.922 0 0 1 1.013.16l3.134-3.133a2.772 2.772 0 0 1-.04-.461c0-.43.108-1.022.589-1.503a.5.5 0 0 1 .353-.146z"/>
                </svg>
              {/if}
              {col.label}
              {#if col.id !== 'message'}
                <!-- svelte-ignore a11y-no-noninteractive-element-interactions -->
                <div class="resize-handle" role="separator" aria-orientation="vertical" tabindex="-1" on:mousedown={(e) => startResize(e, col.id)}></div>
              {/if}
            </th>
          {/each}
        </tr>
      </thead>
      <tbody>
        {#each logs as log, i (log.id || i)}
          <tr
            class="log-row"
            class:selected={selectedLog?.id === log.id}
            on:click={() => selectLog(log)}
          >
            {#each orderedVisibleColumns as col (col.id)}
              <td
                style={col.width ? `width: ${col.width}px` : ''}
                class:pinned={col.pinned}
              >
                {#if col.id === 'time'}
                  <span class="timestamp" title={formatFullTimestamp(log.timestamp)}>
                    {formatTimestamp(log.timestamp)}
                  </span>
                {:else if col.id === 'level'}
                  <span class="level-badge" style="background: {getLevelColor(log.level)}20; color: {getLevelColor(log.level)}">
                    {log.level}
                  </span>
                {:else if col.id === 'service'}
                  <span class="service">{log.service}</span>
                {:else if col.id === 'host'}
                  <span class="host">{log.host}</span>
                {:else if col.id === 'namespace'}
                  <span class="namespace">{getMetaField(log, 'namespace')}</span>
                {:else if col.id === 'pod'}
                  <span class="pod">{getMetaField(log, 'pod')}</span>
                {:else if col.id === 'node'}
                  <span class="node">{getMetaField(log, 'node')}</span>
                {:else if col.id === 'message'}
                  <!-- eslint-disable-next-line svelte/no-at-html-tags -->
                  <span class="message">{@html highlightText(log.message, searchQuery)}</span>
                {/if}
              </td>
            {/each}
          </tr>

          {#if selectedLog?.id === log.id}
            <tr class="detail-row">
              <td colspan={colspanCount}>
                <div class="log-detail">
                  <div class="detail-actions">
                    <button class="copy-btn" on:click|stopPropagation={() => copyToClipboard(log.raw || log.message)} title="Copy raw log">
                      Copy
                    </button>
                    <button class="copy-btn" on:click|stopPropagation={() => copyToClipboard(JSON.stringify(log, null, 2))} title="Copy as JSON">
                      JSON
                    </button>
                    <button
                      class="context-btn"
                      class:active={contextData[log.id]}
                      on:click|stopPropagation={() => loadContext(log.id)}
                      title="Show surrounding logs"
                      disabled={contextLoading[log.id]}
                    >
                      {#if contextLoading[log.id]}
                        Loading...
                      {:else if contextData[log.id]}
                        Hide Context
                      {:else}
                        Show Context
                      {/if}
                    </button>
                  </div>

                  <div class="detail-lines">
                    <button type="button" class="detail-line" class:copied={copiedField === `${log.id}-timestamp`} on:click|stopPropagation={() => copyToClipboard(log.timestamp, `${log.id}-timestamp`)}>
                      <span class="line-key">timestamp</span>
                      <span class="line-value mono">{log.timestamp}</span>
                      <span class="copy-feedback">{copiedField === `${log.id}-timestamp` ? 'Copied!' : ''}</span>
                    </button>
                    <button type="button" class="detail-line" class:copied={copiedField === `${log.id}-level`} on:click|stopPropagation={() => copyToClipboard(log.level, `${log.id}-level`)}>
                      <span class="line-key">level</span>
                      <span class="line-value" style="color: {getLevelColor(log.level)}">{log.level}</span>
                      <span class="copy-feedback">{copiedField === `${log.id}-level` ? 'Copied!' : ''}</span>
                    </button>
                    <button type="button" class="detail-line" class:copied={copiedField === `${log.id}-service`} on:click|stopPropagation={() => copyToClipboard(log.service, `${log.id}-service`)}>
                      <span class="line-key">service</span>
                      <span class="line-value blue">{log.service}</span>
                      <span class="copy-feedback">{copiedField === `${log.id}-service` ? 'Copied!' : ''}</span>
                    </button>
                    <button type="button" class="detail-line" class:copied={copiedField === `${log.id}-host`} on:click|stopPropagation={() => copyToClipboard(log.host, `${log.id}-host`)}>
                      <span class="line-key">host</span>
                      <span class="line-value purple">{log.host}</span>
                      <span class="copy-feedback">{copiedField === `${log.id}-host` ? 'Copied!' : ''}</span>
                    </button>
                    <button type="button" class="detail-line msg" class:copied={copiedField === `${log.id}-message`} on:click|stopPropagation={() => copyToClipboard(log.message, `${log.id}-message`)}>
                      <span class="line-key">message</span>
                      <!-- eslint-disable-next-line svelte/no-at-html-tags -->
                      <span class="line-value mono">{@html highlightText(log.message, searchQuery)}</span>
                      <span class="copy-feedback">{copiedField === `${log.id}-message` ? 'Copied!' : ''}</span>
                    </button>

                    {#if log.meta}
                      {@const parsedMeta = typeof log.meta === 'string' ? (() => { try { return JSON.parse(log.meta); } catch { return null; } })() : log.meta}
                      {#if parsedMeta && typeof parsedMeta === 'object' && Object.keys(parsedMeta).length > 0}
                        {#each Object.entries(parsedMeta) as [key, value]}
                          <button type="button" class="detail-line meta" class:copied={copiedField === `${log.id}-${key}`} on:click|stopPropagation={() => copyToClipboard(String(value), `${log.id}-${key}`)}>
                            <span class="line-key">{key}</span>
                            <span class="line-value mono">{typeof value === 'object' ? JSON.stringify(value) : value}</span>
                            <span class="copy-feedback">{copiedField === `${log.id}-${key}` ? 'Copied!' : ''}</span>
                          </button>
                        {/each}
                      {/if}
                    {/if}

                    {#if log.trace_id}
                      <button type="button" class="detail-line trace" on:click|stopPropagation={() => filterByTrace(log.trace_id)} title="Filter by trace ID">
                        <span class="line-key">trace_id</span>
                        <span class="line-value mono trace-link">{log.trace_id}</span>
                        <span class="trace-action">Filter</span>
                      </button>
                    {/if}

                    {#if log.request_id}
                      <button type="button" class="detail-line trace" on:click|stopPropagation={() => filterByRequest(log.request_id)} title="Filter by request ID">
                        <span class="line-key">request_id</span>
                        <span class="line-value mono trace-link">{log.request_id}</span>
                        <span class="trace-action">Filter</span>
                      </button>
                    {/if}

                    {#if log.span_id}
                      <button type="button" class="detail-line" on:click|stopPropagation={() => copyToClipboard(log.span_id)}>
                        <span class="line-key">span_id</span>
                        <span class="line-value mono">{log.span_id}</span>
                      </button>
                    {/if}

                    {#if log.parent_span_id}
                      <button type="button" class="detail-line" on:click|stopPropagation={() => copyToClipboard(log.parent_span_id)}>
                        <span class="line-key">parent_span</span>
                        <span class="line-value mono">{log.parent_span_id}</span>
                      </button>
                    {/if}

                    {#if log.raw && log.raw !== log.message}
                      <div class="detail-line raw">
                        <span class="line-key">raw</span>
                        <pre class="line-value mono">{log.raw}</pre>
                      </div>
                    {/if}
                  </div>

                  <!-- Context Panel -->
                  {#if contextData[log.id]}
                    <div class="context-panel">
                      <div class="context-header">
                        <span class="context-title">
                          Context: {contextData[log.id].before_count} before, {contextData[log.id].after_count} after
                        </span>
                        <button class="context-close" on:click|stopPropagation={() => closeContext(log.id)}>
                          Close
                        </button>
                      </div>
                      <div class="context-logs">
                        <!-- Before logs -->
                        {#each contextData[log.id].before_logs as ctxLog}
                          <div class="context-log before">
                            <span class="ctx-time">{formatTimestamp(ctxLog.timestamp)}</span>
                            <span class="ctx-level" style="color: {getLevelColor(ctxLog.level)}">{ctxLog.level}</span>
                            <span class="ctx-message">{ctxLog.message}</span>
                          </div>
                        {/each}

                        <!-- Current log marker -->
                        <div class="context-log current">
                          <span class="ctx-time">{formatTimestamp(log.timestamp)}</span>
                          <span class="ctx-level" style="color: {getLevelColor(log.level)}">{log.level}</span>
                          <span class="ctx-message">{log.message}</span>
                          <span class="ctx-marker">← Current</span>
                        </div>

                        <!-- After logs -->
                        {#each contextData[log.id].after_logs as ctxLog}
                          <div class="context-log after">
                            <span class="ctx-time">{formatTimestamp(ctxLog.timestamp)}</span>
                            <span class="ctx-level" style="color: {getLevelColor(ctxLog.level)}">{ctxLog.level}</span>
                            <span class="ctx-message">{ctxLog.message}</span>
                          </div>
                        {/each}
                      </div>
                    </div>
                  {/if}
                </div>
              </td>
            </tr>
          {/if}
        {/each}
      </tbody>
    </table>
  {/if}
</div>

<style>
  .log-table-container {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    overflow: auto;
    max-height: calc(100vh - 280px);
  }

  .table-toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: #21262d;
    border-bottom: 1px solid #30363d;
  }

  .column-menu-container {
    position: relative;
  }

  .toolbar-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #c9d1d9;
    font-size: 12px;
    cursor: pointer;
  }

  .toolbar-btn:hover {
    background: #30363d;
  }

  .toolbar-info {
    font-size: 12px;
    color: #8b949e;
  }

  .toolbar-btn-text {
    font-weight: 500;
  }

  .preset-badge {
    padding: 2px 6px;
    background: #388bfd30;
    color: #58a6ff;
    border-radius: 4px;
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .column-menu {
    position: absolute;
    top: 100%;
    left: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 10px;
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.6);
    z-index: 100;
    min-width: 300px;
    max-height: 500px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .column-menu-search {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px;
    border-bottom: 1px solid #30363d;
    background: #0d1117;
  }

  .column-menu-search svg {
    color: #6e7681;
    flex-shrink: 0;
  }

  .column-search-input {
    flex: 1;
    background: transparent;
    border: none;
    color: #c9d1d9;
    font-size: 13px;
    outline: none;
  }

  .column-search-input::placeholder {
    color: #6e7681;
  }

  .column-presets {
    padding: 10px 12px;
    background: #0d1117;
  }

  .presets-label {
    display: block;
    font-size: 10px;
    font-weight: 600;
    color: #6e7681;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-bottom: 8px;
  }

  .preset-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .preset-chip {
    padding: 5px 10px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 20px;
    color: #c9d1d9;
    font-size: 11px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .preset-chip:hover {
    background: #30363d;
    border-color: #8b949e;
  }

  .preset-chip.active {
    background: #388bfd30;
    border-color: #58a6ff;
    color: #58a6ff;
  }

  .column-menu-divider {
    height: 1px;
    background: #30363d;
  }

  .column-groups {
    flex: 1;
    overflow-y: auto;
    padding: 8px 0;
  }

  .column-group {
    margin-bottom: 4px;
  }

  .group-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    font-size: 11px;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .group-header svg {
    opacity: 0.7;
  }

  .group-count {
    margin-left: auto;
    font-size: 10px;
    color: #6e7681;
    font-weight: 500;
  }

  .group-columns {
    padding: 0 4px;
  }

  .column-item {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px;
    margin: 2px 0;
    border-radius: 6px;
    cursor: grab;
    transition: all 0.15s;
  }

  .column-item:hover {
    background: #21262d;
  }

  .column-item.visible {
    background: #21262d40;
  }

  .column-item.dragging {
    opacity: 0.5;
    background: #30363d;
  }

  .column-item.drag-over {
    border-top: 2px solid #58a6ff;
    margin-top: 0;
    padding-top: 6px;
  }

  .drag-handle {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    color: #6e7681;
    opacity: 0.5;
    cursor: grab;
  }

  .column-item:hover .drag-handle {
    opacity: 1;
  }

  .column-checkbox {
    position: relative;
    display: flex;
    align-items: center;
    cursor: pointer;
  }

  .column-checkbox input {
    position: absolute;
    opacity: 0;
    cursor: pointer;
    height: 0;
    width: 0;
  }

  .checkmark {
    width: 16px;
    height: 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.15s;
  }

  .column-checkbox input:checked ~ .checkmark {
    background: #238636;
    border-color: #238636;
  }

  .column-checkbox input:checked ~ .checkmark::after {
    content: '';
    width: 4px;
    height: 8px;
    border: solid white;
    border-width: 0 2px 2px 0;
    transform: rotate(45deg);
    margin-bottom: 2px;
  }

  .column-label {
    flex: 1;
    font-size: 13px;
    color: #c9d1d9;
  }

  .pin-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    background: transparent;
    border: none;
    color: #6e7681;
    cursor: pointer;
    border-radius: 4px;
    opacity: 0;
    transition: all 0.15s;
  }

  .column-item:hover .pin-btn {
    opacity: 1;
  }

  .pin-btn:hover {
    background: #30363d;
    color: #c9d1d9;
  }

  .pin-btn.pinned {
    opacity: 1;
    color: #58a6ff;
  }

  .column-menu-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px 12px;
    border-top: 1px solid #30363d;
    background: #0d1117;
  }

  .reset-link {
    display: flex;
    align-items: center;
    gap: 6px;
    background: none;
    border: none;
    color: #8b949e;
    font-size: 12px;
    cursor: pointer;
    padding: 4px 8px;
    border-radius: 4px;
    transition: all 0.15s;
  }

  .reset-link:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .visible-count {
    font-size: 11px;
    color: #6e7681;
  }

  th.pinned,
  td.pinned {
    background: #21262d;
    position: sticky;
    left: 0;
    z-index: 1;
  }

  td.pinned {
    background: #161b22;
  }

  .log-row:hover td.pinned {
    background: #1c2128;
  }

  .log-row.selected td.pinned {
    background: #388bfd15;
  }

  th .pin-icon {
    margin-right: 4px;
    color: #58a6ff;
    vertical-align: middle;
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 60px 20px;
    color: #8b949e;
  }

  .empty-state svg {
    margin-bottom: 16px;
    color: #30363d;
  }

  .empty-state p {
    font-size: 16px;
    font-weight: 500;
    margin-bottom: 4px;
  }

  .empty-state span {
    font-size: 14px;
    color: #6e7681;
  }

  .log-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }

  thead {
    background: #21262d;
    position: sticky;
    top: 0;
  }

  th {
    padding: 10px 12px;
    text-align: left;
    font-weight: 500;
    color: #8b949e;
    border-bottom: 1px solid #30363d;
    white-space: nowrap;
    position: relative;
    user-select: none;
  }

  .resize-handle {
    position: absolute;
    right: 0;
    top: 0;
    bottom: 0;
    width: 4px;
    cursor: col-resize;
    background: transparent;
    transition: background 0.15s;
  }

  .resize-handle:hover,
  .log-table.resizing .resize-handle {
    background: #58a6ff;
  }

  .log-table.resizing {
    cursor: col-resize;
    user-select: none;
  }

  .log-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .log-row:hover {
    background: #1c2128;
  }

  .log-row.selected {
    background: #388bfd15;
  }

  td {
    padding: 8px 12px;
    border-bottom: 1px solid #21262d;
    vertical-align: top;
  }

  .timestamp {
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #8b949e;
  }

  .level-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .service {
    color: #58a6ff;
  }

  .host {
    color: #a371f7;
  }

  .namespace {
    color: #f0883e;
  }

  .pod {
    color: #3fb950;
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
  }

  .node {
    color: #a371f7;
  }

  .message {
    font-family: 'SFMono-Regular', Consolas, monospace;
    word-break: break-all;
    color: #c9d1d9;
  }

  /* Log syntax highlighting */
  :global(.log-uuid) {
    color: #a371f7;
    font-weight: 500;
  }

  :global(.log-id) {
    color: #79c0ff;
    font-weight: 500;
  }

  :global(.log-key) {
    color: #7ee787;
  }

  :global(.log-method) {
    color: #ff7b72;
    font-weight: 600;
  }

  :global(.log-path) {
    color: #a5d6ff;
  }

  :global(.log-ip) {
    color: #ffa657;
  }

  :global(.log-time) {
    color: #8b949e;
  }

  :global(.log-number) {
    color: #79c0ff;
  }

  :global(.log-string) {
    color: #a5d6ff;
  }

  :global(.log-status) {
    font-weight: 600;
    padding: 1px 4px;
    border-radius: 3px;
  }

  :global(.log-status-2), :global(.log-status-200), :global(.log-status-201), :global(.log-status-204) {
    color: #3fb950;
    background: rgba(63, 185, 80, 0.15);
  }

  :global(.log-status-3), :global(.log-status-301), :global(.log-status-302), :global(.log-status-304) {
    color: #58a6ff;
    background: rgba(88, 166, 255, 0.15);
  }

  :global(.log-status-4), :global(.log-status-400), :global(.log-status-401), :global(.log-status-403), :global(.log-status-404) {
    color: #d29922;
    background: rgba(210, 153, 34, 0.15);
  }

  :global(.log-status-5), :global(.log-status-500), :global(.log-status-502), :global(.log-status-503) {
    color: #f85149;
    background: rgba(248, 81, 73, 0.15);
  }

  :global(.log-level-error), :global(.log-level-fatal), :global(.log-level-critical) {
    color: #f85149;
    font-weight: 600;
  }

  :global(.log-level-warn), :global(.log-level-warning) {
    color: #d29922;
    font-weight: 600;
  }

  :global(.log-level-info) {
    color: #3fb950;
  }

  :global(.log-level-debug), :global(.log-level-trace) {
    color: #8b949e;
  }

  .detail-row td {
    padding: 0;
    background: #0d1117;
  }

  .log-detail {
    padding: 12px 16px;
    border-left: 3px solid #30363d;
    margin-left: 8px;
    max-width: 100%;
    overflow: hidden;
  }

  .detail-actions {
    display: flex;
    gap: 6px;
    margin-bottom: 10px;
  }

  .copy-btn {
    padding: 4px 10px;
    background: transparent;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #8b949e;
    font-size: 11px;
    cursor: pointer;
  }

  .copy-btn:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .detail-lines {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .detail-line {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 4px 8px;
    border-radius: 4px;
    cursor: pointer;
    width: 100%;
    text-align: left;
    background: transparent;
    border: none;
  }

  .detail-line:hover {
    background: #161b22;
  }

  .detail-line.copied {
    background: rgba(35, 134, 54, 0.2) !important;
    border-left: 3px solid #3fb950;
  }

  .copy-feedback {
    flex-shrink: 0;
    font-size: 11px;
    color: #3fb950;
    font-weight: 600;
    margin-left: auto;
    padding: 2px 8px;
    opacity: 0;
    transition: opacity 0.1s;
  }

  .detail-line.copied .copy-feedback {
    opacity: 1;
  }

  .detail-line.msg {
    margin-top: 6px;
    padding-top: 8px;
    border-top: 1px solid #21262d;
  }

  .detail-line.meta {
    opacity: 0.85;
  }

  .detail-line.raw {
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid #21262d;
    flex-direction: column;
    gap: 4px;
  }

  .line-key {
    min-width: 80px;
    font-size: 12px;
    color: #6e7681;
  }

  .line-value {
    flex: 1;
    font-size: 13px;
    color: #c9d1d9;
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }

  .line-value.mono {
    font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px;
  }

  .line-value.blue {
    color: #58a6ff;
  }

  .line-value.purple {
    color: #a371f7;
  }

  .detail-line.raw .line-value {
    white-space: pre-wrap;
    background: #161b22;
    padding: 8px;
    border-radius: 4px;
    margin: 0;
  }

  /* Search highlight */
  :global(.search-highlight) {
    background: #f5a623;
    color: #0d1117;
    padding: 1px 2px;
    border-radius: 2px;
    font-weight: 600;
  }

  /* Context button */
  .context-btn {
    padding: 4px 10px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #58a6ff;
    font-size: 11px;
    cursor: pointer;
    transition: all 0.15s;
  }

  .context-btn:hover {
    background: #30363d;
    border-color: #58a6ff;
  }

  .context-btn.active {
    background: #388bfd20;
    border-color: #58a6ff;
  }

  .context-btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  /* Context panel */
  .context-panel {
    margin-top: 12px;
    border: 1px solid #30363d;
    border-radius: 6px;
    background: #0d1117;
    overflow: hidden;
  }

  .context-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    background: #161b22;
    border-bottom: 1px solid #30363d;
  }

  .context-title {
    font-size: 12px;
    color: #8b949e;
    font-weight: 500;
  }

  .context-close {
    padding: 2px 8px;
    background: transparent;
    border: 1px solid #30363d;
    border-radius: 4px;
    color: #8b949e;
    font-size: 11px;
    cursor: pointer;
  }

  .context-close:hover {
    background: #21262d;
    color: #c9d1d9;
  }

  .context-logs {
    max-height: 400px;
    overflow-y: auto;
  }

  .context-log {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 6px 12px;
    font-size: 12px;
    border-bottom: 1px solid #21262d;
  }

  .context-log:last-child {
    border-bottom: none;
  }

  .context-log.before {
    background: #161b2280;
    opacity: 0.7;
  }

  .context-log.after {
    background: #161b2280;
    opacity: 0.7;
  }

  .context-log.current {
    background: #388bfd15;
    border-left: 3px solid #58a6ff;
    font-weight: 500;
  }

  .ctx-time {
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #8b949e;
    flex-shrink: 0;
    width: 70px;
  }

  .ctx-level {
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
    width: 60px;
  }

  .ctx-message {
    flex: 1;
    font-family: 'SFMono-Regular', Consolas, monospace;
    color: #c9d1d9;
    word-break: break-all;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .ctx-marker {
    color: #58a6ff;
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
  }

  /* Trace/Request ID styling */
  .detail-line.trace {
    background: #21262d;
    border: 1px solid #30363d;
    margin-top: 4px;
    border-radius: 4px;
  }

  .detail-line.trace:hover {
    background: #30363d;
    border-color: #58a6ff;
  }

  .trace-link {
    color: #58a6ff;
  }

  .trace-action {
    font-size: 11px;
    color: #8b949e;
    background: #21262d;
    padding: 2px 6px;
    border-radius: 3px;
    flex-shrink: 0;
  }

  .detail-line.trace:hover .trace-action {
    background: #388bfd30;
    color: #58a6ff;
  }
</style>
