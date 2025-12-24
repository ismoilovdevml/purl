<!--
  ColumnPicker Component
  Column configuration menu with search, presets, drag-drop reordering

  Usage:
  <ColumnPicker bind:columns bind:open on:change={saveConfig} />
-->
<script>
  import { createEventDispatcher } from 'svelte';
  import { clickOutside } from '../../utils/dom.js';

  export let columns = [];
  export let open = false;

  const dispatch = createEventDispatcher();

  let columnSearch = '';
  let draggedColumn = null;
  let dragOverColumn = null;

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

  function close() {
    open = false;
    columnSearch = '';
  }

  function toggleColumn(colId) {
    columns = columns.map(c =>
      c.id === colId ? { ...c, visible: !c.visible } : c
    );
    dispatch('change', { columns });
  }

  function togglePin(colId) {
    columns = columns.map(c =>
      c.id === colId ? { ...c, pinned: !c.pinned } : c
    );
    dispatch('change', { columns });
  }

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
    columns.forEach(col => {
      if (!orderedColumns.includes(col)) {
        orderedColumns.push(col);
      }
    });
    columns = orderedColumns;
    dispatch('change', { columns });
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
    dispatch('change', { columns });
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
        dispatch('change', { columns });
      }
    }
    draggedColumn = null;
    dragOverColumn = null;
  }

  function handleDragEnd() {
    draggedColumn = null;
    dragOverColumn = null;
  }

  // Get current preset name if matches
  function getCurrentPreset() {
    const visibleIds = columns.filter(c => c.visible).map(c => c.id);
    return presets.find(p =>
      p.columns.length === visibleIds.length &&
      p.columns.every((id, i) => id === visibleIds[i])
    )?.name || null;
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
  $: currentPreset = getCurrentPreset();
</script>

<div class="column-picker">
  <button class="picker-trigger" on:click|stopPropagation={() => open = !open}>
    <svg width="14" height="14" viewBox="0 0 16 16">
      <path fill="currentColor" d="M1.5 3a.5.5 0 0 0 0 1h13a.5.5 0 0 0 0-1h-13zM1 7.5a.5.5 0 0 1 .5-.5h13a.5.5 0 0 1 0 1h-13a.5.5 0 0 1-.5-.5zm.5 3.5a.5.5 0 0 0 0 1h8a.5.5 0 0 0 0-1h-8z"/>
    </svg>
    <span>Columns</span>
    {#if currentPreset}
      <span class="preset-badge">{currentPreset}</span>
    {/if}
  </button>

  {#if open}
    <div class="picker-dropdown" use:clickOutside={close}>
      <!-- Search -->
      <div class="picker-search">
        <svg width="14" height="14" viewBox="0 0 16 16">
          <path fill="currentColor" d="M11.742 10.344a6.5 6.5 0 1 0-1.397 1.398h-.001c.03.04.062.078.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1.007 1.007 0 0 0-.115-.1zM12 6.5a5.5 5.5 0 1 1-11 0 5.5 5.5 0 0 1 11 0z"/>
        </svg>
        <input
          type="text"
          placeholder="Search columns..."
          bind:value={columnSearch}
        />
      </div>

      <!-- Presets -->
      <div class="picker-presets">
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

      <div class="picker-divider"></div>

      <!-- Grouped columns -->
      <div class="picker-groups">
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
                    role="listitem"
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
                          <path fill="currentColor" d="M9.828.722a.5.5 0 0 1 .354.146l4.95 4.95a.5.5 0 0 1 0 .707c-.48.48-1.072.588-1.503.588-.177 0-.335-.018-.46-.039l-3.134 3.134a5.927 5.927 0 0 1 .16 1.013c.046.702-.032 1.687-.72 2.375a.5.5 0 0 1-.707 0l-2.829-2.828-3.182 3.182c-.195.195-1.219.902-1.414.707-.195-.195.512-1.22.707-1.414l3.182-3.182-2.828-2.829a.5.5 0 0 1 0-.707c.688-.688 1.673-.767 2.375-.72a5.922 5.922 0 0 1 1.013.16l3.134-3.133a2.772 2.772 0 0 1-.04-.461c0-.43.108-1.022.589-1.503a.5.5 0 0 1 .353-.146z"/>
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

      <div class="picker-footer">
        <button class="reset-btn" on:click={resetColumns}>
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

<style>
  .column-picker {
    position: relative;
  }

  .picker-trigger {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-sm, 4px);
    color: var(--text-primary, #c9d1d9);
    font-size: var(--text-sm, 12px);
    font-weight: 500;
    cursor: pointer;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .picker-trigger:hover {
    background: var(--bg-hover, #30363d);
  }

  .preset-badge {
    padding: 2px 6px;
    background: var(--color-primary-bg, rgba(88, 166, 255, 0.15));
    color: var(--color-primary, #58a6ff);
    border-radius: var(--radius-sm, 4px);
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .picker-dropdown {
    position: absolute;
    top: 100%;
    left: 0;
    margin-top: 4px;
    background: var(--bg-secondary, #161b22);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-lg, 10px);
    box-shadow: var(--shadow-xl, 0 12px 40px rgba(0, 0, 0, 0.6));
    z-index: var(--z-dropdown, 100);
    min-width: 300px;
    max-height: 500px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .picker-search {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px;
    border-bottom: 1px solid var(--border-color, #30363d);
    background: var(--bg-primary, #0d1117);
  }

  .picker-search svg {
    color: var(--text-muted, #6e7681);
    flex-shrink: 0;
  }

  .picker-search input {
    flex: 1;
    background: transparent;
    border: none;
    color: var(--text-primary, #c9d1d9);
    font-size: var(--text-base, 13px);
    outline: none;
  }

  .picker-search input::placeholder {
    color: var(--text-muted, #6e7681);
  }

  .picker-presets {
    padding: 10px 12px;
    background: var(--bg-primary, #0d1117);
  }

  .presets-label {
    display: block;
    font-size: 10px;
    font-weight: 600;
    color: var(--text-muted, #6e7681);
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
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: 20px;
    color: var(--text-primary, #c9d1d9);
    font-size: 11px;
    cursor: pointer;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .preset-chip:hover {
    background: var(--bg-hover, #30363d);
    border-color: var(--text-secondary, #8b949e);
  }

  .preset-chip.active {
    background: var(--color-primary-bg, rgba(88, 166, 255, 0.15));
    border-color: var(--color-primary, #58a6ff);
    color: var(--color-primary, #58a6ff);
  }

  .picker-divider {
    height: 1px;
    background: var(--border-color, #30363d);
  }

  .picker-groups {
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
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .group-header svg {
    opacity: 0.7;
  }

  .group-count {
    margin-left: auto;
    font-size: 10px;
    color: var(--text-muted, #6e7681);
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
    border-radius: var(--radius-md, 6px);
    cursor: grab;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .column-item:hover {
    background: var(--bg-tertiary, #21262d);
  }

  .column-item.visible {
    background: rgba(33, 38, 45, 0.4);
  }

  .column-item.dragging {
    opacity: 0.5;
    background: var(--bg-hover, #30363d);
  }

  .column-item.drag-over {
    border-top: 2px solid var(--color-primary, #58a6ff);
    margin-top: 0;
    padding-top: 6px;
  }

  .drag-handle {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    color: var(--text-muted, #6e7681);
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
    background: var(--bg-tertiary, #21262d);
    border: 1px solid var(--border-color, #30363d);
    border-radius: var(--radius-sm, 4px);
    display: flex;
    align-items: center;
    justify-content: center;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .column-checkbox input:checked ~ .checkmark {
    background: var(--color-success, #238636);
    border-color: var(--color-success, #238636);
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
    font-size: var(--text-base, 13px);
    color: var(--text-primary, #c9d1d9);
  }

  .pin-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    background: transparent;
    border: none;
    color: var(--text-muted, #6e7681);
    cursor: pointer;
    border-radius: var(--radius-sm, 4px);
    opacity: 0;
    transition: var(--transition-fast, all 0.15s ease);
  }

  .column-item:hover .pin-btn {
    opacity: 1;
  }

  .pin-btn:hover {
    background: var(--bg-hover, #30363d);
    color: var(--text-primary, #c9d1d9);
  }

  .pin-btn.pinned {
    opacity: 1;
    color: var(--color-primary, #58a6ff);
  }

  .picker-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px 12px;
    border-top: 1px solid var(--border-color, #30363d);
    background: var(--bg-primary, #0d1117);
  }

  .reset-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    background: none;
    border: none;
    color: var(--text-secondary, #8b949e);
    font-size: var(--text-sm, 12px);
    cursor: pointer;
    padding: 4px 8px;
    border-radius: var(--radius-sm, 4px);
    transition: var(--transition-fast, all 0.15s ease);
  }

  .reset-btn:hover {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .visible-count {
    font-size: 11px;
    color: var(--text-muted, #6e7681);
  }
</style>
