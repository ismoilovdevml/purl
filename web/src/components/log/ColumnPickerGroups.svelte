<!--
  ColumnPickerGroups
  The column list inside ColumnPicker, grouped by section (core, kubernetes,
  ...). Each item toggles visibility, pins, and can be dragged to reorder.
  ColumnPicker owns the column array; this only reports what the user did.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { checkCircle, grip, layers, pinAngle, table } from '../ui/icons.js';

  let {
    /** Columns to list (already filtered by the picker's search box) */
    columns,
    /** (columnId) => void — visibility checkbox changed */
    ontoggle,
    /** (columnId) => void — pin button clicked */
    onpin,
    /** (draggedId, targetId) => void — an item was dropped onto another */
    onreorder,
  } = $props();

  let draggedColumn = $state(null);
  let dragOverColumn = $state(null);

  // Column groups for organization. `icon` holds the imported glyph itself —
  // never raw path data — so icons.js stays tree-shakeable.
  const columnGroups = {
    core: { label: 'Core Fields', icon: table },
    kubernetes: { label: 'Kubernetes', icon: layers },
    tracing: { label: 'Tracing', icon: checkCircle }
  };

  // Group columns for display
  const groupedColumns = $derived(Object.keys(columnGroups).reduce((acc, group) => {
    acc[group] = columns.filter(c => c.group === group);
    return acc;
  }, {}));

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
      onreorder(draggedColumn, targetId);
    }
    draggedColumn = null;
    dragOverColumn = null;
  }

  function handleDragEnd() {
    draggedColumn = null;
    dragOverColumn = null;
  }
</script>

<div class="picker-groups">
  {#each Object.entries(groupedColumns) as [groupKey, groupCols]}
    {#if groupCols.length > 0}
      <div class="column-group">
        <div class="group-header">
          <Icon icon={columnGroups[groupKey].icon} size={12} strokeWidth={3} class="group-icon" />
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
              ondragstart={(e) => handleDragStart(e, col.id)}
              ondragover={(e) => handleDragOver(e, col.id)}
              ondragleave={handleDragLeave}
              ondrop={(e) => handleDrop(e, col.id)}
              ondragend={handleDragEnd}
              role="listitem"
            >
              <div class="drag-handle" title="Drag to reorder">
                <Icon icon={grip} size={10} />
              </div>
              <label class="column-checkbox">
                <input
                  type="checkbox"
                  checked={col.visible}
                  onchange={() => ontoggle(col.id)}
                />
                <span class="checkmark"></span>
              </label>
              <span class="column-label">{col.label}</span>
              {#if col.visible}
                <button
                  class="pin-btn"
                  class:pinned={col.pinned}
                  onclick={(e) => { e.stopPropagation(); onpin(col.id); }}
                  title={col.pinned ? 'Unpin column' : 'Pin column to left'}
                  aria-label={col.pinned ? `Unpin ${col.label} column` : `Pin ${col.label} column to left`}
                  aria-pressed={col.pinned}
                >
                  <Icon icon={pinAngle} size={12} />
                </button>
              {/if}
            </div>
          {/each}
        </div>
      </div>
    {/if}
  {/each}
</div>

<style>
  .picker-groups {
    flex: 1;
    /* Lets the list shrink below its content inside a clamped ColumnPicker
       panel, so it scrolls instead of being cut off (#118). */
    min-height: 0;
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
    color: var(--text-secondary);
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .group-header :global(.group-icon) {
    opacity: 0.7;
  }

  .group-count {
    margin-left: auto;
    font-size: 10px;
    color: var(--text-muted);
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
    border-radius: var(--radius-md);
    cursor: grab;
    transition: var(--transition-fast);
  }

  .column-item:hover {
    background: var(--bg-tertiary);
  }

  .column-item.visible {
    background: rgba(33, 38, 45, 0.4);
  }

  .column-item.dragging {
    opacity: 0.5;
    background: var(--bg-hover);
  }

  .column-item.drag-over {
    border-top: 2px solid var(--color-primary);
    margin-top: 0;
    padding-top: 6px;
  }

  .drag-handle {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    color: var(--text-muted);
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
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    display: flex;
    align-items: center;
    justify-content: center;
    transition: var(--transition-fast);
  }

  .column-checkbox input:checked ~ .checkmark {
    background: var(--color-success-solid);
    border-color: var(--color-success-solid);
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
    font-size: var(--text-base);
    color: var(--text-primary);
  }

  .pin-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 4px;
    background: transparent;
    border: none;
    color: var(--text-muted);
    cursor: pointer;
    border-radius: var(--radius-sm);
    opacity: 0;
    transition: var(--transition-fast);
  }

  .column-item:hover .pin-btn {
    opacity: 1;
  }

  .pin-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .pin-btn.pinned {
    opacity: 1;
    color: var(--color-primary);
  }
</style>
