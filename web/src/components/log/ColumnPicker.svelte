<!--
  ColumnPicker Component
  Column configuration menu with search, presets, drag-drop reordering

  Usage:
  <ColumnPicker bind:columns bind:open onchange={({ columns }) => saveConfig(columns)} />
-->
<script>
  import { clickOutside, fitToViewport } from '../../utils/dom.js';
  import { defaultColumns } from '../../utils/columns.js';
  import Icon from '../ui/Icon.svelte';
  import { refresh, search, textLines } from '../ui/icons.js';
  import ColumnPickerGroups from './ColumnPickerGroups.svelte';

  let {
    columns = $bindable([]),
    open = $bindable(false),
    /** ({ columns }) after any visibility/pin/order change */
    onchange,
  } = $props();

  let columnSearch = $state('');

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
    onchange?.({ columns });
  }

  function togglePin(colId) {
    columns = columns.map(c =>
      c.id === colId ? { ...c, pinned: !c.pinned } : c
    );
    onchange?.({ columns });
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
    onchange?.({ columns });
  }

  function resetColumns() {
    columns = defaultColumns();
    onchange?.({ columns });
  }

  // Move the dragged column to the drop target's position
  function moveColumn(draggedId, targetId) {
    const dragIdx = columns.findIndex(c => c.id === draggedId);
    const targetIdx = columns.findIndex(c => c.id === targetId);

    if (dragIdx !== -1 && targetIdx !== -1) {
      const newColumns = [...columns];
      const [removed] = newColumns.splice(dragIdx, 1);
      newColumns.splice(targetIdx, 0, removed);
      columns = newColumns;
      onchange?.({ columns });
    }
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
  const filteredColumns = $derived(
    columnSearch
      ? columns.filter(c => c.label.toLowerCase().includes(columnSearch.toLowerCase()))
      : columns
  );

  const visibleColumns = $derived(columns.filter(c => c.visible));
  const currentPreset = $derived(getCurrentPreset());
</script>

<div class="column-picker">
  <button class="picker-trigger" onclick={(e) => { e.stopPropagation(); open = !open; }}>
    <Icon icon={textLines} size={14} strokeWidth={2.5} />
    <span>Columns</span>
    {#if currentPreset}
      <span class="preset-badge">{currentPreset}</span>
    {/if}
  </button>

  {#if open}
    <!-- Clamped to the viewport (opens upward when there is more room above);
         the column list scrolls inside it (#118). -->
    <div class="picker-dropdown" use:clickOutside={close} use:fitToViewport={{ vertical: true }}>
      <!-- Search -->
      <div class="picker-search">
        <Icon icon={search} size={14} strokeWidth={2.5} class="search-icon" />
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
              onclick={() => applyPreset(preset)}
              title={preset.columns.join(', ')}
            >
              {preset.name}
            </button>
          {/each}
        </div>
      </div>

      <div class="picker-divider"></div>

      <!-- Grouped columns -->
      <ColumnPickerGroups
        columns={filteredColumns}
        ontoggle={toggleColumn}
        onpin={togglePin}
        onreorder={moveColumn}
      />

      <div class="picker-footer">
        <button class="reset-btn" onclick={resetColumns}>
          <Icon icon={refresh} size={12} strokeWidth={3} />
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
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: var(--text-sm);
    font-weight: 500;
    cursor: pointer;
    transition: var(--transition-fast);
  }

  .picker-trigger:hover {
    background: var(--bg-hover);
  }

  .preset-badge {
    padding: 2px 6px;
    background: var(--color-primary-bg);
    color: var(--color-primary);
    border-radius: var(--radius-sm);
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
  }

  .picker-dropdown {
    position: absolute;
    top: 100%;
    left: 0;
    margin-top: 4px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-xl);
    box-shadow: var(--shadow-xl);
    z-index: var(--z-dropdown);
    min-width: 300px;
    max-height: 500px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  /* Only the column list shrinks when the panel is clamped; the search,
     presets and footer keep their height. */
  .picker-search,
  .picker-presets,
  .picker-divider,
  .picker-footer {
    flex-shrink: 0;
  }

  .picker-search {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px;
    border-bottom: 1px solid var(--border-color);
    background: var(--bg-primary);
  }

  .picker-search :global(.search-icon) {
    color: var(--text-muted);
    flex-shrink: 0;
  }

  .picker-search input {
    flex: 1;
    background: transparent;
    border: none;
    color: var(--text-primary);
    font-size: var(--text-base);
  }

  .picker-search input::placeholder {
    color: var(--text-muted);
  }

  .picker-presets {
    padding: 10px 12px;
    background: var(--bg-primary);
  }

  .presets-label {
    display: block;
    font-size: 10px;
    font-weight: 600;
    color: var(--text-muted);
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
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 20px;
    color: var(--text-primary);
    font-size: 11px;
    cursor: pointer;
    transition: var(--transition-fast);
  }

  .preset-chip:hover {
    background: var(--bg-hover);
    border-color: var(--text-secondary);
  }

  .preset-chip.active {
    background: var(--color-primary-bg);
    border-color: var(--color-primary);
    color: var(--color-primary);
  }

  .picker-divider {
    height: 1px;
    background: var(--border-color);
  }

  .picker-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px 12px;
    border-top: 1px solid var(--border-color);
    background: var(--bg-primary);
  }

  .reset-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    background: none;
    border: none;
    color: var(--text-secondary);
    font-size: var(--text-sm);
    cursor: pointer;
    padding: 4px 8px;
    border-radius: var(--radius-sm);
    transition: var(--transition-fast);
  }

  .reset-btn:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .visible-count {
    font-size: 11px;
    color: var(--text-muted);
  }
</style>
