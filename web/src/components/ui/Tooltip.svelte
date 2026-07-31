<!--
  Tooltip Component
  Hover/focus tooltip with customizable position

  Usage:
  <Tooltip content="Copy to clipboard">
    <button>Copy</button>
  </Tooltip>
-->
<script>
  /** Tooltip text */
  export let content = '';

  /** Position */
  export let position = 'top'; // top, bottom, left, right

  /** Show delay in ms */
  export let delay = 200;

  /** Disabled state */
  export let disabled = false;

  let visible = false;
  let timeout;

  function show() {
    if (disabled || !content) return;
    timeout = setTimeout(() => {
      visible = true;
    }, delay);
  }

  function hide() {
    clearTimeout(timeout);
    visible = false;
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="tooltip-wrapper"
  on:mouseenter={show}
  on:mouseleave={hide}
  on:focusin={show}
  on:focusout={hide}
>
  <slot />

  {#if visible && content}
    <div
      class="tooltip"
      class:position-top={position === 'top'}
      class:position-bottom={position === 'bottom'}
      class:position-left={position === 'left'}
      class:position-right={position === 'right'}
      role="tooltip"
    >
      {content}
      <span class="tooltip-arrow"></span>
    </div>
  {/if}
</div>

<style>
  .tooltip-wrapper {
    position: relative;
    display: inline-flex;
  }

  .tooltip {
    position: absolute;
    z-index: var(--z-tooltip);
    padding: var(--space-1) var(--space-2);
    font-size: var(--text-xs);
    font-weight: 500;
    color: var(--text-primary);
    background: var(--bg-elevated);
    border: 1px solid var(--border-strong);
    border-radius: var(--radius-sm);
    box-shadow: var(--shadow-lg);
    white-space: nowrap;
    pointer-events: none;
    animation: tooltip-fade 0.15s ease;
  }

  .tooltip-arrow {
    position: absolute;
    width: 8px;
    height: 8px;
    background: var(--bg-elevated);
    border: 1px solid var(--border-strong);
    transform: rotate(45deg);
  }

  /* Position: Top (default) */
  .tooltip.position-top {
    bottom: 100%;
    left: 50%;
    transform: translateX(-50%);
    margin-bottom: 8px;
  }

  .tooltip.position-top .tooltip-arrow {
    bottom: -5px;
    left: 50%;
    transform: translateX(-50%) rotate(45deg);
    border-top: none;
    border-left: none;
  }

  /* Position: Bottom */
  .tooltip.position-bottom {
    top: 100%;
    left: 50%;
    transform: translateX(-50%);
    margin-top: 8px;
  }

  .tooltip.position-bottom .tooltip-arrow {
    top: -5px;
    left: 50%;
    transform: translateX(-50%) rotate(45deg);
    border-bottom: none;
    border-right: none;
  }

  /* Position: Left */
  .tooltip.position-left {
    right: 100%;
    top: 50%;
    transform: translateY(-50%);
    margin-right: 8px;
  }

  .tooltip.position-left .tooltip-arrow {
    right: -5px;
    top: 50%;
    transform: translateY(-50%) rotate(45deg);
    border-left: none;
    border-bottom: none;
  }

  /* Position: Right */
  .tooltip.position-right {
    left: 100%;
    top: 50%;
    transform: translateY(-50%);
    margin-left: 8px;
  }

  .tooltip.position-right .tooltip-arrow {
    left: -5px;
    top: 50%;
    transform: translateY(-50%) rotate(45deg);
    border-right: none;
    border-top: none;
  }

  @keyframes tooltip-fade {
    from {
      opacity: 0;
    }
    to {
      opacity: 1;
    }
  }
</style>
