<!--
  PatternItem
  One row of the patterns sidebar: level, service and count on top, the
  pattern template below with its <UUID>/<IP>/<NUM>/... placeholders
  highlighted. The pattern text goes through highlightPattern(), which
  HTML-escapes it before re-inserting the placeholder spans, so the {@html}
  below never renders raw log content.
-->
<script>
  import { highlightPattern } from '../../stores/logs.js';
  import { getLevelColor } from '../../utils/colors.js';

  let {
    /** { pattern_hash, pattern, level, service, count } */
    pattern,
    /** Pre-formatted occurrence count shown in the badge */
    countLabel,
    /** This row is the active pattern filter */
    selected = false,
    /** () => void */
    onselect,
  } = $props();
</script>

<button
  class="pattern-item"
  class:selected
  onclick={() => onselect?.()}
>
  <div class="pattern-header">
    <span class="pattern-level" style="color: {getLevelColor(pattern.level)}">
      {pattern.level}
    </span>
    <span class="pattern-service">{pattern.service}</span>
    <span class="pattern-count">{countLabel}</span>
  </div>
  <div class="pattern-text">
    <!-- eslint-disable-next-line svelte/no-at-html-tags -->
    {@html highlightPattern(pattern.pattern)}
  </div>
</button>

<style>
  .pattern-item {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 10px 12px;
    background: transparent;
    border: none;
    border-bottom: 1px solid #21262d;
    cursor: pointer;
    text-align: left;
    transition: background 0.1s;
    width: 100%;
  }

  .pattern-item:hover {
    background: #1c2128;
  }

  .pattern-item.selected {
    background: #388bfd15;
    border-left: 3px solid #58a6ff;
  }

  .pattern-header {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 11px;
  }

  .pattern-level {
    font-weight: 600;
    text-transform: uppercase;
  }

  .pattern-service {
    color: #58a6ff;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .pattern-count {
    color: #8b949e;
    background: #21262d;
    padding: 2px 6px;
    border-radius: 10px;
    font-weight: 500;
  }

  .pattern-text {
    font-family: var(--font-mono);
    font-size: 11px;
    color: #c9d1d9;
    line-height: 1.4;
    overflow: hidden;
    text-overflow: ellipsis;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    word-break: break-all;
  }

  /* Placeholder highlighting */
  :global(.placeholder) {
    padding: 1px 4px;
    border-radius: 3px;
    font-weight: 600;
    font-size: 10px;
  }

  :global(.placeholder.uuid) {
    background: #a371f720;
    color: #a371f7;
  }

  :global(.placeholder.ip) {
    background: #3fb95020;
    color: #3fb950;
  }

  :global(.placeholder.num) {
    background: #58a6ff20;
    color: #58a6ff;
  }

  :global(.placeholder.datetime) {
    background: #d2992220;
    color: #d29922;
  }

  :global(.placeholder.hex) {
    background: #f8514920;
    color: #f85149;
  }
</style>
