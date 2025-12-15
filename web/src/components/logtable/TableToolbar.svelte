<script>
  import { createEventDispatcher } from 'svelte';

  export let columns = [];
  export let logsCount = 0;

  const dispatch = createEventDispatcher();

  let showColumnMenu = false;

  function toggleColumn(colId) {
    dispatch('toggleColumn', colId);
  }

  function resetColumns() {
    dispatch('resetColumns');
  }
</script>

<div class="table-toolbar">
  <div class="column-menu-container">
    <button class="toolbar-btn" on:click={() => showColumnMenu = !showColumnMenu} title="Configure columns">
      <svg width="14" height="14" viewBox="0 0 14 14">
        <path fill="currentColor" d="M1 2h12v2H1V2Zm0 4h12v2H1V6Zm0 4h8v2H1v-2Z"/>
      </svg>
      Columns
    </button>
    {#if showColumnMenu}
      <div class="column-menu">
        <div class="column-menu-header">
          <span>Show/Hide Columns</span>
          <button class="reset-btn" on:click={resetColumns}>Reset</button>
        </div>
        {#each columns as col}
          <label class="column-option">
            <input type="checkbox" checked={col.visible} on:change={() => toggleColumn(col.id)} />
            <span>{col.label}</span>
          </label>
        {/each}
      </div>
    {/if}
  </div>
  <span class="toolbar-info">{logsCount} logs</span>
</div>

<style>
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

  .column-menu {
    position: absolute;
    top: 100%;
    left: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
    z-index: 100;
    min-width: 240px;
    overflow: hidden;
  }

  .column-menu-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid #30363d;
    font-size: 13px;
    font-weight: 500;
    color: #c9d1d9;
  }

  .reset-btn {
    background: none;
    border: none;
    color: #58a6ff;
    cursor: pointer;
    font-size: 12px;
    padding: 4px 8px;
    border-radius: 4px;
  }

  .reset-btn:hover {
    background: #21262d;
  }

  .column-option {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 16px;
    cursor: pointer;
    font-size: 14px;
    color: #c9d1d9;
    transition: background 0.1s;
  }

  .column-option:hover {
    background: #21262d;
  }

  .column-option input {
    width: 16px;
    height: 16px;
    accent-color: #58a6ff;
  }
</style>
