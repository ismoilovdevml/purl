<!--
  UnhealthyPodsTable
  Sortable table of unhealthy pods on the K8s Pod Health page. Clicking a row
  dispatches a document-level `filter-logs` event so the app can jump to that
  pod's logs. Sort state is owned by K8sPage so it survives the table
  unmounting between refreshes.
-->
<script>
  import { formatShortDateTime } from '../../utils/format.js';
  import { getErrorStyle } from '../../utils/k8sErrorStyles.js';

  let {
    /** Pods, already sorted */
    pods = [],
    /** Total unhealthy pods reported by the backend */
    total = 0,
    /** A refresh is in flight (shows the inline spinner) */
    loading = false,
    /** Current sort column key */
    sortColumn,
    /** 'asc' | 'desc' */
    sortDirection,
    /** (column) => void — a sortable header was clicked */
    onsort,
  } = $props();


  function relativeTime(ts) {
    if (!ts) return '';
    try {
      const now = Date.now();
      const then = new Date(ts).getTime();
      const diffSec = Math.floor((now - then) / 1000);
      if (diffSec < 60) return `${diffSec}s ago`;
      if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`;
      if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`;
      return `${Math.floor(diffSec / 86400)}d ago`;
    } catch {
      return '';
    }
  }

  function sortIndicator(column) {
    if (sortColumn !== column) return '';
    return sortDirection === 'asc' ? ' \u2191' : ' \u2193';
  }

  function handlePodClick(pod) {
    // Dispatch a custom event for parent to handle log navigation
    const event = new CustomEvent('filter-logs', {
      bubbles: true,
      detail: {
        namespace: pod.namespace,
        pod_name: pod.pod_name,
        error_type: pod.error_type,
      },
    });
    document.dispatchEvent(event);
  }
</script>

<div class="table-section">
  <div class="table-header">
    <h2>Unhealthy Pods <span class="count-badge">{total}</span></h2>
    {#if loading}
      <div class="inline-spinner"></div>
    {/if}
  </div>
  <div class="table-wrapper">
    <table class="pods-table">
      <thead>
        <tr>
          <th class="sortable" onclick={() => onsort('namespace')}>
            Namespace{sortIndicator('namespace')}
          </th>
          <th class="sortable" onclick={() => onsort('pod_name')}>
            Pod Name{sortIndicator('pod_name')}
          </th>
          <th class="sortable" onclick={() => onsort('container')}>
            Container{sortIndicator('container')}
          </th>
          <th class="sortable" onclick={() => onsort('error_type')}>
            Error Type{sortIndicator('error_type')}
          </th>
          <th class="sortable numeric" onclick={() => onsort('count')}>
            Count{sortIndicator('count')}
          </th>
          <th class="sortable" onclick={() => onsort('first_seen')}>
            First Seen{sortIndicator('first_seen')}
          </th>
          <th class="sortable" onclick={() => onsort('last_seen')}>
            Last Seen{sortIndicator('last_seen')}
          </th>
        </tr>
      </thead>
      <tbody>
        {#each pods as pod}
          <tr class="pod-row" onclick={() => handlePodClick(pod)} title="Click to filter logs">
            <td>
              <span class="namespace-tag">{pod.namespace}</span>
            </td>
            <td class="pod-name-cell">
              <span class="pod-name-text">{pod.pod_name}</span>
            </td>
            <td>
              <span class="container-name">{pod.container || '-'}</span>
            </td>
            <td>
              <span
                class="error-badge"
                style="color: {getErrorStyle(pod.error_type).color}; background: {getErrorStyle(pod.error_type).bg}; border-color: {getErrorStyle(pod.error_type).border}"
              >
                {pod.error_type}
              </span>
            </td>
            <td class="count-cell">
              {pod.count}
            </td>
            <td class="timestamp-cell" title={formatShortDateTime(pod.first_seen)}>
              {relativeTime(pod.first_seen)}
            </td>
            <td class="timestamp-cell" title={formatShortDateTime(pod.last_seen)}>
              {relativeTime(pod.last_seen)}
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
</div>

<style>
  .inline-spinner {
    width: 14px;
    height: 14px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  /* Table section */
  .table-section {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
    overflow: hidden;
  }

  .table-header {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 16px;
    border-bottom: 1px solid #21262d;
  }

  .table-header h2 {
    font-size: 0.8125rem;
    font-weight: 600;
    color: #c9d1d9;
    margin: 0;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .count-badge {
    background: #21262d;
    color: #8b949e;
    font-size: 0.6875rem;
    padding: 2px 8px;
    border-radius: 10px;
    font-weight: 500;
  }

  .table-wrapper {
    overflow-x: auto;
  }

  .pods-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.8125rem;
  }

  .pods-table th {
    text-align: left;
    padding: 10px 14px;
    font-size: 0.6875rem;
    font-weight: 600;
    color: #8b949e;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    border-bottom: 1px solid #21262d;
    background: #0d1117;
    white-space: nowrap;
    user-select: none;
  }

  .pods-table th.sortable {
    cursor: pointer;
    transition: color 0.15s;
  }

  .pods-table th.sortable:hover {
    color: #c9d1d9;
  }

  .pods-table th.numeric {
    text-align: right;
  }

  .pods-table td {
    padding: 10px 14px;
    border-bottom: 1px solid #21262d;
    color: #c9d1d9;
    vertical-align: middle;
  }

  .pod-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .pod-row:hover td {
    background: rgba(88, 166, 255, 0.04);
  }

  .pod-row:last-child td {
    border-bottom: none;
  }

  /* Namespace tag */
  .namespace-tag {
    display: inline-block;
    padding: 2px 8px;
    background: rgba(163, 113, 247, 0.1);
    border: 1px solid rgba(163, 113, 247, 0.25);
    border-radius: 4px;
    font-size: 0.6875rem;
    color: #a371f7;
    font-family: var(--font-mono);
  }

  /* Pod name */
  .pod-name-cell {
    max-width: 280px;
  }

  .pod-name-text {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #58a6ff;
    word-break: break-all;
  }

  /* Container name */
  .container-name {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #8b949e;
  }

  /* Error type badge */
  .error-badge {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 12px;
    font-size: 0.6875rem;
    font-weight: 600;
    border: 1px solid;
    white-space: nowrap;
  }

  /* Count cell */
  .count-cell {
    text-align: right;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: #f0f6fc;
  }

  /* Timestamp cell */
  .timestamp-cell {
    font-size: 0.75rem;
    color: #8b949e;
    white-space: nowrap;
  }

  /* Responsive */
  @media (max-width: 768px) {
    .pods-table {
      font-size: 0.75rem;
    }

    .pods-table th,
    .pods-table td {
      padding: 8px 10px;
    }

    .pod-name-cell {
      max-width: 160px;
    }
  }
</style>
