<!--
  DashboardAddWidgetMenu
  The "+ Add Widget" button of an open dashboard, with its hover menu of
  widget types. DashboardPage creates the widget.
-->
<script>
  import Button from '../ui/Button.svelte';
  import Icon from '../ui/Icon.svelte';
  import { hash, activity, table, terminal } from '../ui/icons.js';

  let {
    /** (type) => void — a widget type was picked */
    onadd,
  } = $props();

  // Widget type options. `icon` holds the imported glyph itself, not a name —
  // that is what keeps icons.js tree-shakeable.
  const widgetTypes = [
    { value: 'counter', label: 'Counter', icon: hash },
    { value: 'chart', label: 'Time Chart', icon: activity },
    { value: 'table', label: 'Top Values', icon: table },
    { value: 'log_stream', label: 'Log Stream', icon: terminal },
  ];
</script>

<div class="add-widget-dropdown">
  <Button>+ Add Widget</Button>
  <div class="widget-menu">
    {#each widgetTypes as wt}
      <button onclick={() => onadd(wt.value)}>
        <span class="widget-icon"><Icon icon={wt.icon} size={14} strokeWidth={2.5} /></span>
        {wt.label}
      </button>
    {/each}
  </div>
</div>

<style>
  .add-widget-dropdown {
    position: relative;
  }

  .add-widget-dropdown:hover .widget-menu {
    display: block;
  }

  .widget-menu {
    display: none;
    position: absolute;
    top: 100%;
    right: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.4);
    z-index: 200;
    min-width: 160px;
    padding: 4px 0;
  }

  .widget-menu button {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 8px 14px;
    background: none;
    border: none;
    color: #c9d1d9;
    font-size: 13px;
    cursor: pointer;
    text-align: left;
  }

  .widget-menu button:hover {
    background: #21262d;
  }

  .widget-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    color: #58a6ff;
  }
</style>
