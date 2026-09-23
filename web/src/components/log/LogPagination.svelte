<!--
  LogPagination
  Footer under the log table: "Showing X–Y of N", the truncation warning when
  the result count hit the max-results cap, and Prev/Next page buttons.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import { chevronLeft, chevronRight } from '../ui/icons.js';

  let {
    /** Total number of logs in the result set */
    total,
    /** 1-based index of the first row on this page */
    pageStart,
    /** 1-based index of the last row on this page */
    pageEnd,
    currentPage,
    totalPages,
    /** Clamped max-results setting; reaching it means results may be cut off */
    maxResults,
    /** () => void */
    onprev,
    /** () => void */
    onnext,
  } = $props();
</script>

<div class="pagination-footer">
  <span class="pagination-info">
    {#if total > 0}
      Showing {pageStart}–{pageEnd} of {total} results
    {/if}
    {#if total >= maxResults}
      <span class="truncation-note">Results may be truncated. Showing max {maxResults} logs.</span>
    {/if}
  </span>
  <div class="pagination-controls">
    <button
      class="page-btn"
      onclick={onprev}
      disabled={currentPage === 1}
      aria-label="Previous page"
    >
      <Icon icon={chevronLeft} size={14} strokeWidth={3} />
      Prev
    </button>
    <span class="page-indicator">Page {currentPage} of {totalPages}</span>
    <button
      class="page-btn"
      onclick={onnext}
      disabled={currentPage === totalPages}
      aria-label="Next page"
    >
      Next
      <Icon icon={chevronRight} size={14} strokeWidth={3} />
    </button>
  </div>
</div>

<style>
  .pagination-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: var(--bg-tertiary);
    border-top: 1px solid var(--border-color);
    font-size: var(--text-sm);
    color: var(--text-secondary);
    position: sticky;
    bottom: 0;
    z-index: 2;
  }

  .pagination-info {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .truncation-note {
    color: var(--color-highlight);
    font-size: 11px;
  }

  .pagination-controls {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .page-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px 10px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: var(--text-sm);
    cursor: pointer;
    transition: background 0.15s;
  }

  .page-btn:hover:not(:disabled) {
    background: var(--border-color);
  }

  .page-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .page-indicator {
    font-size: var(--text-sm);
    color: var(--text-secondary);
    min-width: 80px;
    text-align: center;
  }
</style>
