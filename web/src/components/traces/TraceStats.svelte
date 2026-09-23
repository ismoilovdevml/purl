<!--
  TraceStats
  Summary strip above a looked-up trace/request: id, kind, counts, duration
  and a per-level breakdown.
-->
<script>
  import Badge from '../ui/Badge.svelte';
  import { formatDuration } from '../../utils/format.js';
  import { getLevelVariant } from '../../utils/colors.js';

  /**
   * @type {{
   *   id: string,
   *   searchType: 'trace' | 'request',
   *   total: number,
   *   serviceCount: number,
   *   durationMs: number,
   *   levelCounts: Record<string, number>,
   * }}
   */
  let { id, searchType, total, serviceCount, durationMs, levelCounts } = $props();
</script>

<div class="stats-bar">
  <div class="stat-item">
    <span class="stat-label">ID</span>
    <span class="stat-value mono">{id}</span>
  </div>
  <div class="stat-item">
    <span class="stat-label">Type</span>
    <span class="stat-value">{searchType === 'trace' ? 'Trace' : 'Request'}</span>
  </div>
  <div class="stat-item">
    <span class="stat-label">Logs</span>
    <span class="stat-value">{total}</span>
  </div>
  <div class="stat-item">
    <span class="stat-label">Services</span>
    <span class="stat-value">{serviceCount}</span>
  </div>
  {#if durationMs > 0}
    <div class="stat-item">
      <span class="stat-label">Duration</span>
      <span class="stat-value">{formatDuration(durationMs)}</span>
    </div>
  {/if}
  {#each Object.entries(levelCounts) as [level, count] (level)}
    <div class="stat-item">
      <Badge variant={getLevelVariant(level)} size="sm" pill>{level}: {count}</Badge>
    </div>
  {/each}
</div>

<style>
  .stats-bar {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    padding: 10px 14px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    margin-bottom: 16px;
    align-items: center;
    flex-shrink: 0;
  }

  .stat-item {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .stat-label {
    font-size: 0.6875rem;
    color: #848d97;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #f0f6fc;
  }

  .stat-value.mono {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #58a6ff;
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  @media (max-width: 900px) {
    .stats-bar {
      gap: 10px;
    }

    .stat-value.mono {
      max-width: 140px;
    }
  }

  @media (max-width: 640px) {
    .stats-bar {
      flex-direction: column;
      gap: 8px;
    }
  }
</style>
