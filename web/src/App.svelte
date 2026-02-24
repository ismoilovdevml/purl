<script>
  import { onMount, onDestroy } from 'svelte';
  import SearchBar from './components/SearchBar.svelte';
  import TimeRangePicker from './components/TimeRangePicker.svelte';
  import FieldsSidebar from './components/FieldsSidebar.svelte';
  import LogTable from './components/log/LogTable.svelte';
  import Histogram from './components/Histogram.svelte';
  import SavedSearches from './components/SavedSearches.svelte';
  import AlertsPanel from './components/AlertsPanel.svelte';
  import PatternsSidebar from './components/PatternsSidebar.svelte';
  import AnalyticsPage from './components/AnalyticsPage.svelte';
  import SettingsPage from './components/settings/SettingsPage.svelte';
  import DashboardPage from './components/dashboard/DashboardPage.svelte';
  import TracesPage from './components/TracesPage.svelte';
  import K8sPage from './components/K8sPage.svelte';
  import QueryPage from './components/QueryPage.svelte';
  import LoginPage from './components/LoginPage.svelte';
  import SearchHelp from './components/SearchHelp.svelte';
  import Toast from './components/ui/Toast.svelte';
  import ClusterSelector from './components/ui/ClusterSelector.svelte';
  import {
    logs,
    loading,
    error,
    query,
    timeRange,
    customTimeRange,
    total,
    searchLogs,
  } from './stores/logs.js';
  import { refreshInterval, defaultTimeRange } from './stores/settings.js';
  import { fetchLicense, currentPlan, isPaidPlan, isTrialPlan, trialDaysRemaining, licenseFeatures } from './stores/license.js';
  import { currentUser, checkAuth, logout, passwordChangeRequired } from './stores/auth.js';
  import { success as toastSuccess, warning as toastWarning } from './stores/toast.js';
  import { fetchClusters, clusters } from './stores/cluster.js';
  import { initAI } from './stores/ai.js';

  let savedSearchesRef;
  let currentPage = 'logs'; // 'logs' | 'analytics' | 'traces' | 'k8s' | 'query' | 'dashboards' | 'settings'
  let showSearchHelp = false;
  let refreshIntervalId = null;
  let currentRefreshInterval = 30;
  let hasAppliedDefaultRange = false;
  let unsubscribeRefresh = null;
  let unsubscribeDefaultRange = null;
  let appReady = false;

  $: hasDashboards = ($licenseFeatures || []).includes('dashboards');

  // Mobile responsive state
  let mobileMenuOpen = false;
  let isMobile = false;

  function checkMobile() {
    isMobile = window.innerWidth < 768;
    if (!isMobile) mobileMenuOpen = false;
  }

  // Enhanced error state with retry callback and severity
  let errorState = { message: '', retryFn: null, severity: 'error' };
  let errorDismissTimer = null;

  // Selected logs for bulk export
  let selectedLogs = [];
  // Export progress indicator for large exports
  let exportStatus = '';

  // Sync the logs store error into local errorState (auto-set retry to searchLogs)
  $: if ($error) {
    setError($error, searchLogs, 'error');
  } else if (!$error && errorState.retryFn === searchLogs) {
    clearError();
  }

  function setError(message, retryFn = null, severity = 'error') {
    if (errorDismissTimer) clearTimeout(errorDismissTimer);
    errorState = { message, retryFn, severity };
    // Auto-dismiss after 10 seconds
    errorDismissTimer = setTimeout(() => {
      clearError();
    }, 10000);
  }

  function clearError() {
    if (errorDismissTimer) {
      clearTimeout(errorDismissTimer);
      errorDismissTimer = null;
    }
    errorState = { message: '', retryFn: null, severity: 'error' };
    error.set(null);
  }

  function setupRefreshInterval() {
    // Clear existing interval
    if (refreshIntervalId) {
      clearInterval(refreshIntervalId);
      refreshIntervalId = null;
    }

    // Set up new interval if enabled (> 0), on logs page, and not awaiting password change
    if (currentRefreshInterval > 0 && currentPage === 'logs' && !$passwordChangeRequired) {
      refreshIntervalId = setInterval(() => {
        searchLogs();
      }, currentRefreshInterval * 1000);
    }
  }

  async function handleLogout() {
    await logout();
    currentPage = 'logs';
  }

  onMount(async () => {
    // Fetch license info first
    await fetchLicense();

    // If Pro/Enterprise, check session auth
    if ($isPaidPlan) {
      await checkAuth();
    }

    appReady = true;

    // Subscribe to refresh interval changes
    unsubscribeRefresh = refreshInterval.subscribe(v => {
      currentRefreshInterval = v;
      setupRefreshInterval();
    });

    // Subscribe to default time range (apply on first load)
    unsubscribeDefaultRange = defaultTimeRange.subscribe(v => {
      if (!hasAppliedDefaultRange && v) {
        $timeRange = v;
        hasAppliedDefaultRange = true;
      }
    });

    // Check URL hash for navigation
    handleHashChange();
    window.addEventListener('hashchange', handleHashChange);

    // Mobile responsive: check on mount and listen for resize
    checkMobile();
    window.addEventListener('resize', checkMobile);

    // Only fetch data if user is authenticated (or free plan)
    const needsAuth = $isPaidPlan && !$currentUser;
    if (!needsAuth && !$passwordChangeRequired) {
      fetchClusters();
      initAI();
      if (currentPage === 'logs') {
        await searchLogs();
      }
    }

    return () => {
      window.removeEventListener('hashchange', handleHashChange);
      window.removeEventListener('resize', checkMobile);
    };
  });

  onDestroy(() => {
    if (unsubscribeRefresh) unsubscribeRefresh();
    if (unsubscribeDefaultRange) unsubscribeDefaultRange();
    if (refreshIntervalId) {
      clearInterval(refreshIntervalId);
    }
    if (errorDismissTimer) {
      clearTimeout(errorDismissTimer);
    }
  });

  function handleHashChange() {
    const hash = window.location.hash.slice(1) || 'logs';
    if (['logs', 'analytics', 'traces', 'k8s', 'query', 'dashboards', 'settings'].includes(hash)) {
      if (hash === 'dashboards' && !hasDashboards) {
        currentPage = 'logs';
        window.location.hash = 'logs';
        toastWarning('Custom Dashboards requires a Pro or Enterprise license');
        return;
      }
      currentPage = hash;
    }
  }

  function navigate(page) {
    if (page === 'dashboards' && !hasDashboards) {
      toastWarning('Custom Dashboards requires a Pro or Enterprise license');
      return;
    }
    currentPage = page;
    window.location.hash = page;
    mobileMenuOpen = false;
    // Restart refresh interval when navigating to logs
    if (page === 'logs') {
      setupRefreshInterval();
    } else if (refreshIntervalId) {
      clearInterval(refreshIntervalId);
      refreshIntervalId = null;
    }
  }

  function handleSearch() {
    searchLogs();
  }

  function handleClusterChange() {
    searchLogs();
  }

  function handleTimeRangeChange(event) {
    const { range, from, to } = event.detail;
    $timeRange = range;
    if (range === 'custom' && from && to) {
      $customTimeRange = { from, to };
    } else {
      $customTimeRange = { from: null, to: null };
    }
    searchLogs();
  }

  function handleFieldFilter(event) {
    const { value } = event.detail;
    $query = value;
    searchLogs();
  }

  function handleApplySavedSearch(event) {
    const { query: q, timeRange: tr } = event.detail;
    $query = q;
    $timeRange = tr;
    searchLogs();
  }

  function handleHistogramFilter(event) {
    const { start, end } = event.detail;
    $timeRange = 'custom';
    $customTimeRange = { from: start, to: end };
    searchLogs();
  }

  function handleHistogramZoom(event) {
    const { start, end } = event.detail;
    $timeRange = 'custom';
    $customTimeRange = { from: start, to: end };
    searchLogs();
  }

  function saveCurrentSearch() {
    savedSearchesRef?.openSaveModal($query, $timeRange);
  }

  // Handle selection changes from LogTable (receives IDs, resolve to full log objects)
  function handleSelectionChange(event) {
    const selectedIds = event.detail?.selected || [];
    const idSet = new Set(selectedIds);
    selectedLogs = $logs.filter(l => idSet.has(l.id));
  }

  function exportCSV(logsToExport) {
    if (!logsToExport || logsToExport.length === 0) return;

    if (logsToExport.length > 100) {
      exportStatus = 'preparing';
    }

    // Collect all unique meta keys across all logs
    const metaKeys = [...new Set(
      logsToExport.flatMap(l => Object.keys(l.meta || l.parsedMeta || {}))
    )].sort();

    const headers = ['timestamp', 'level', 'service', 'host', 'message',
                     ...metaKeys.map(k => `meta.${k}`)];

    const rows = logsToExport.map(log => {
      const metaObj = log.meta || log.parsedMeta || {};
      return [
        log.timestamp || '',
        log.level || '',
        log.service || '',
        log.host || '',
        `"${(log.message || '').replace(/"/g, '""')}"`,
        ...metaKeys.map(k => `"${((metaObj[k] !== undefined ? metaObj[k] : '') + '').replace(/"/g, '""')}"`)
      ];
    });

    const csv = [headers.join(','), ...rows.map(r => r.join(','))].join('\n');
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
    downloadBlob(blob, `purl-logs-${Date.now()}.csv`);
    exportStatus = '';
    toastSuccess(`Exported ${logsToExport.length} logs as CSV`);
  }

  function exportJSON(logsToExport) {
    if (!logsToExport || logsToExport.length === 0) return;

    if (logsToExport.length > 100) {
      exportStatus = 'preparing';
    }

    const json = JSON.stringify(logsToExport, null, 2);
    const blob = new Blob([json], { type: 'application/json' });
    downloadBlob(blob, `purl-logs-${Date.now()}.json`);
    exportStatus = '';
    toastSuccess(`Exported ${logsToExport.length} logs as JSON`);
  }

  function downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }
</script>

{#if !appReady}
  <div class="app-loading">
    <svg width="48" height="48" viewBox="0 0 32 32">
      <circle cx="16" cy="16" r="14" fill="none" stroke="#58a6ff" stroke-width="2"/>
      <path d="M10 12 L22 12 M10 16 L22 16 M10 20 L18 20" stroke="#58a6ff" stroke-width="2" stroke-linecap="round"/>
    </svg>
  </div>
{:else if $isPaidPlan && (!$currentUser || $passwordChangeRequired)}
  <LoginPage on:login={() => { fetchClusters(); searchLogs(); }} />
{:else}
<main>
  <header>
    {#if isMobile}
      <button class="hamburger" on:click={() => mobileMenuOpen = !mobileMenuOpen} aria-label="Toggle menu">
        <span class="hamburger-line"></span>
        <span class="hamburger-line"></span>
        <span class="hamburger-line"></span>
      </button>
    {/if}
    <button class="logo" on:click={() => navigate('logs')}>
      <svg width="32" height="32" viewBox="0 0 32 32">
        <circle
          cx="16"
          cy="16"
          r="14"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        />
        <path
          d="M10 12 L22 12 M10 16 L22 16 M10 20 L18 20"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
        />
      </svg>
      <span>Purl</span>
      {#if $isTrialPlan}
        <span class="plan-badge trial">Trial</span>
      {:else if $isPaidPlan}
        <span class="plan-badge" class:enterprise={$currentPlan === 'enterprise'}>
          {$currentPlan === 'enterprise' ? 'Enterprise' : 'Pro'}
        </span>
      {/if}
    </button>

    <nav class="nav-tabs">
      <button
        class:active={currentPage === 'logs'}
        on:click={() => navigate('logs')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z" />
          <path d="M14 2v6h6M16 13H8M16 17H8M10 9H8" />
        </svg>
        Logs
      </button>
      <button
        class:active={currentPage === 'analytics'}
        on:click={() => navigate('analytics')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <path d="M3 3v18h18" />
          <path d="M18 9l-5-6-4 8-3-2" />
        </svg>
        Analytics
      </button>
      <button
        class:active={currentPage === 'traces'}
        on:click={() => navigate('traces')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
        </svg>
        Traces
      </button>
      <button
        class:active={currentPage === 'k8s'}
        on:click={() => navigate('k8s')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <path d="M12 2L2 7l10 5 10-5-10-5z" />
          <path d="M2 17l10 5 10-5" />
          <path d="M2 12l10 5 10-5" />
        </svg>
        K8s
      </button>
      <button
        class:active={currentPage === 'query'}
        on:click={() => navigate('query')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <polyline points="16 18 22 12 16 6" />
          <polyline points="8 6 2 12 8 18" />
        </svg>
        Query
      </button>
      <button
        class:active={currentPage === 'dashboards'}
        class:locked={!hasDashboards}
        on:click={() => navigate('dashboards')}
      >
        {#if hasDashboards}
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <rect x="3" y="3" width="7" height="7" rx="1" />
            <rect x="14" y="3" width="7" height="7" rx="1" />
            <rect x="3" y="14" width="7" height="7" rx="1" />
            <rect x="14" y="14" width="7" height="7" rx="1" />
          </svg>
        {:else}
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>
            <path d="M7 11V7a5 5 0 0 1 10 0v4"/>
          </svg>
        {/if}
        Dashboards
        {#if !hasDashboards}
          <span class="pro-badge">Pro</span>
        {/if}
      </button>
      <button
        class:active={currentPage === 'settings'}
        on:click={() => navigate('settings')}
      >
        <svg
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <circle cx="12" cy="12" r="3" />
          <path
            d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-2 2 2 2 0 01-2-2v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83 0 2 2 0 010-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 01-2-2 2 2 0 012-2h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 010-2.83 2 2 0 012.83 0l.06.06a1.65 1.65 0 001.82.33H9a1.65 1.65 0 001-1.51V3a2 2 0 012-2 2 2 0 012 2v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 0 2 2 0 010 2.83l-.06.06a1.65 1.65 0 00-.33 1.82V9a1.65 1.65 0 001.51 1H21a2 2 0 012 2 2 2 0 01-2 2h-.09a1.65 1.65 0 00-1.51 1z"
          />
        </svg>
        Settings
      </button>
    </nav>

    {#if $currentUser}
      <div class="user-menu">
        <span class="user-name">{$currentUser.username}</span>
        <button class="btn btn-sm" on:click={handleLogout}>Logout</button>
      </div>
    {/if}

    {#if currentPage === 'logs'}
      <SearchBar bind:value={$query} on:search={handleSearch} />
      <button class="search-help-btn" on:click={() => showSearchHelp = true} title="Search syntax help">?</button>

      <div class="header-actions">
        {#if $clusters.length > 0}
          <ClusterSelector on:change={handleClusterChange} />
        {/if}
        <TimeRangePicker value={$timeRange} on:change={handleTimeRangeChange} />

        {#if selectedLogs.length > 0}
          <div class="actions-dropdown">
            <button class="btn btn-selected dropdown-trigger">
              Export Selected ({selectedLogs.length})
              <svg
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"><path d="M6 9l6 6 6-6" /></svg
              >
            </button>
            <div class="dropdown-menu">
              <button on:click={() => exportCSV(selectedLogs)}>
                <svg width="14" height="14" viewBox="0 0 14 14"
                  ><path
                    fill="currentColor"
                    d="M2 1h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1Zm1 3h6v1H3V4Zm0 2h6v1H3V6Zm0 2h4v1H3V8Z"
                  /></svg
                >
                Export CSV
              </button>
              <button on:click={() => exportJSON(selectedLogs)}>
                <svg width="14" height="14" viewBox="0 0 14 14"
                  ><path
                    fill="currentColor"
                    d="M3 2a1 1 0 0 0-1 1v2a1 1 0 0 1-1 1 1 1 0 0 1 1 1v2a1 1 0 0 0 1 1M9 2a1 1 0 0 1 1 1v2a1 1 0 0 0 1 1 1 1 0 0 0-1 1v2a1 1 0 0 1-1 1"
                  /></svg
                >
                Export JSON
              </button>
            </div>
          </div>
        {/if}

        <div class="actions-dropdown">
          <button class="btn dropdown-trigger">
            Actions
            <svg
              width="12"
              height="12"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"><path d="M6 9l6 6 6-6" /></svg
            >
          </button>

          <div class="dropdown-menu">
            <button on:click={saveCurrentSearch}>
              <svg width="14" height="14" viewBox="0 0 14 14"
                ><path
                  fill="currentColor"
                  d="M11 1H3a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2ZM7 10a2 2 0 1 1 0-4 2 2 0 0 1 0 4Zm3-6H4V2h6v2Z"
                /></svg
              >
              Save Search
            </button>
            <div class="divider"></div>
            <button on:click={() => exportCSV($logs)} disabled={$logs.length === 0}>
              <svg width="14" height="14" viewBox="0 0 14 14"
                ><path
                  fill="currentColor"
                  d="M2 1h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1Zm1 3h6v1H3V4Zm0 2h6v1H3V6Zm0 2h4v1H3V8Z"
                /></svg
              >
              Export CSV
            </button>
            <button on:click={() => exportJSON($logs)} disabled={$logs.length === 0}>
              <svg width="14" height="14" viewBox="0 0 14 14"
                ><path
                  fill="currentColor"
                  d="M3 2a1 1 0 0 0-1 1v2a1 1 0 0 1-1 1 1 1 0 0 1 1 1v2a1 1 0 0 0 1 1M9 2a1 1 0 0 1 1 1v2a1 1 0 0 0 1 1 1 1 0 0 0-1 1v2a1 1 0 0 1-1 1"
                /></svg
              >
              Export JSON
            </button>
          </div>
        </div>

        <button class="btn" on:click={handleSearch} disabled={$loading}>
          {#if $loading}
            <span class="spinner"></span>
          {:else}
            Refresh
          {/if}
        </button>
      </div>
    {/if}
  </header>

  {#if $isTrialPlan}
    <div class="trial-banner">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="12" cy="12" r="10"/>
        <path d="M12 6v6l4 2"/>
      </svg>
      <span>
        <strong>Pro Trial</strong> — {$trialDaysRemaining} {$trialDaysRemaining === 1 ? 'day' : 'days'} remaining
      </span>
      <a href="https://purlogs.com/pricing" target="_blank" rel="noopener" class="trial-upgrade-btn">
        Upgrade to Pro
      </a>
    </div>
  {/if}

  {#if exportStatus === 'preparing'}
    <div class="info-banner" role="status">
      <span class="spinner spinner-sm"></span>
      <span>Preparing export...</span>
    </div>
  {/if}

  {#if errorState.message}
    <div class="error-banner severity-{errorState.severity}" role="alert">
      <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
        <path
          fill="currentColor"
          d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-2.75a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0V6a.75.75 0 0 1 .75-.75Zm0 7a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
        />
      </svg>
      <span>{errorState.message}</span>
      {#if errorState.retryFn}
        <button class="retry-btn" on:click={errorState.retryFn} aria-label="Retry">
          Retry
        </button>
      {/if}
      <button
        class="dismiss-btn"
        on:click={clearError}
        aria-label="Dismiss error"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
          <path
            fill="currentColor"
            d="M7 5.586 3.707 2.293a1 1 0 0 0-1.414 1.414L5.586 7 2.293 10.293a1 1 0 1 0 1.414 1.414L7 8.414l3.293 3.293a1 1 0 0 0 1.414-1.414L8.414 7l3.293-3.293a1 1 0 0 0-1.414-1.414L7 5.586Z"
          />
        </svg>
      </button>
    </div>
  {/if}

  {#if currentPage === 'logs'}
    <div class="stats-bar">
        <span>{$total.toLocaleString()} logs</span>
        <span class="separator">|</span>
        <span>Time range: {$timeRange}</span>
        {#if $query}
          <span class="separator">|</span>
          <span>Query: <code>{$query}</code></span>
        {/if}
        {#if selectedLogs.length > 0}
          <span class="separator">|</span>
          <span class="selection-info">{selectedLogs.length} selected</span>
        {/if}
      </div>

      <div class="container">
        {#if isMobile && mobileMenuOpen}
          <div class="sidebar-backdrop visible" on:click={() => mobileMenuOpen = false} on:keydown={() => mobileMenuOpen = false} role="button" tabindex="-1" aria-label="Close menu"></div>
        {/if}

        <aside class="sidebar" class:mobile-open={isMobile && mobileMenuOpen}>
          <FieldsSidebar on:filter={handleFieldFilter} />
          <SavedSearches
            bind:this={savedSearchesRef}
            on:apply={handleApplySavedSearch}
          />
          <AlertsPanel />
        </aside>

        <div class="main-content">
          <Histogram on:filter={handleHistogramFilter} on:zoom={handleHistogramZoom} />
          <LogTable logs={$logs} on:selectionChange={handleSelectionChange} />
        </div>

        <aside class="patterns-aside">
          <PatternsSidebar />
        </aside>
      </div>
  {:else if currentPage === 'analytics'}
    <AnalyticsPage />
  {:else if currentPage === 'traces'}
    <TracesPage />
  {:else if currentPage === 'k8s'}
    <K8sPage />
  {:else if currentPage === 'query'}
    <QueryPage />
  {:else if currentPage === 'dashboards'}
    <DashboardPage />
  {:else if currentPage === 'settings'}
    <SettingsPage />
  {/if}

  {#if showSearchHelp}
    <SearchHelp onClose={() => showSearchHelp = false} />
  {/if}
</main>
{/if}

<Toast />

<style>
  :global(*) {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }

  :global(body) {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen,
      Ubuntu, sans-serif;
    background: #0d1117;
    color: #c9d1d9;
    line-height: 1.5;
    overflow: hidden;
  }

  main {
    height: 100vh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  header {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 12px 20px;
    background: #161b22;
    border-bottom: 1px solid #30363d;
    position: sticky;
    top: 0;
    z-index: 100;
  }

  .logo {
    display: flex;
    align-items: center;
    gap: 8px;
    color: #58a6ff;
    font-weight: 600;
    font-size: 18px;
    background: none;
    border: none;
    cursor: pointer;
    padding: 0;
  }

  .logo:hover {
    color: #79c0ff;
  }

  .plan-badge {
    font-size: 10px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 9999px;
    background: rgba(88, 166, 255, 0.15);
    color: #58a6ff;
    letter-spacing: 0.02em;
  }

  .plan-badge.enterprise {
    background: rgba(163, 113, 247, 0.15);
    color: #a371f7;
  }

  .user-menu {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-left: auto;
  }

  .user-name {
    font-size: 13px;
    color: #8b949e;
  }

  .btn-sm {
    padding: 4px 10px;
    font-size: 11px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    transition: all 0.15s;
  }

  .btn-sm:hover {
    background: #30363d;
  }

  .app-loading {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100vh;
    background: #0d1117;
  }

  .nav-tabs {
    display: flex;
    gap: 4px;
    background: #0d1117;
    padding: 4px;
    border-radius: 8px;
  }

  .nav-tabs button {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 14px;
    background: transparent;
    border: none;
    border-radius: 6px;
    color: #8b949e;
    font-size: 13px;
    cursor: pointer;
    transition: all 0.2s;
  }

  .nav-tabs button:hover {
    color: #c9d1d9;
    background: #21262d;
  }

  .nav-tabs button.active {
    color: #f0f6fc;
    background: #21262d;
  }

  .nav-tabs button svg {
    opacity: 0.7;
  }

  .nav-tabs button.active svg {
    opacity: 1;
  }

  .nav-tabs button.locked {
    opacity: 0.5;
  }

  .nav-tabs button.locked:hover {
    opacity: 0.7;
  }

  .pro-badge {
    font-size: 10px;
    padding: 1px 5px;
    border-radius: 4px;
    background: #388bfd26;
    color: #58a6ff;
    font-weight: 600;
    line-height: 1.4;
  }

  .header-actions {
    display: flex;
    gap: 8px;
    margin-left: auto;
  }

  .stats-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 20px;
    background: #0d1117;
    border-bottom: 1px solid #21262d;
    font-size: 12px;
    color: #8b949e;
  }

  .stats-bar .separator {
    color: #30363d;
  }

  .stats-bar code {
    background: #21262d;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: "SFMono-Regular", Consolas, monospace;
    color: #58a6ff;
  }

  .selection-info {
    color: #58a6ff;
    font-weight: 500;
  }

  .btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 16px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 14px;
    transition: all 0.2s;
  }

  .btn:hover {
    background: #30363d;
  }

  .btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .btn-selected {
    border-color: #388bfd;
    color: #58a6ff;
  }

  .btn-selected:hover {
    background: rgba(56, 139, 253, 0.1);
  }

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid #30363d;
    border-top-color: #58a6ff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .spinner-sm {
    width: 12px;
    height: 12px;
    flex-shrink: 0;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .container {
    display: flex;
    flex: 1;
    overflow: hidden;
    max-height: calc(100vh - 100px);
  }

  .sidebar {
    width: 280px;
    background: #161b22;
    border-right: 1px solid #30363d;
    padding: 16px;
    overflow-y: auto;
    flex-shrink: 0;
  }

  .main-content {
    flex: 1;
    padding: 16px;
    overflow: auto;
  }

  .patterns-aside {
    padding: 16px;
    padding-left: 0;
    flex-shrink: 0;
  }

  .actions-dropdown {
    position: relative;
  }

  .actions-dropdown:hover .dropdown-menu,
  .actions-dropdown:focus-within .dropdown-menu {
    display: block;
  }

  .dropdown-trigger {
    padding-right: 12px;
  }

  .dropdown-trigger svg {
    opacity: 0.6;
    margin-left: 2px;
  }

  .dropdown-menu {
    display: none;
    position: absolute;
    top: 100%;
    right: 0;
    margin-top: 4px;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 6px;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    z-index: 200;
    min-width: 160px;
    overflow: hidden;
    padding: 4px 0;
  }

  .dropdown-menu button {
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
    transition: background 0.15s;
  }

  .dropdown-menu button:hover {
    background: #21262d;
  }

  .dropdown-menu button:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .dropdown-menu button svg {
    color: #8b949e;
  }

  .divider {
    height: 1px;
    background: #30363d;
    margin: 4px 0;
  }

  /* Info banner (export progress) */
  .info-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 16px;
    background: rgba(56, 139, 253, 0.1);
    border-bottom: 1px solid rgba(56, 139, 253, 0.3);
    color: #58a6ff;
    font-size: 13px;
  }

  /* Error banner with severity variants */
  .error-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 16px;
    background: rgba(248, 81, 73, 0.1);
    border-bottom: 1px solid #f85149;
    color: #f85149;
    font-size: 13px;
  }

  .error-banner.severity-warning {
    background: rgba(210, 153, 34, 0.1);
    border-bottom-color: #d29922;
    color: #d29922;
  }

  .error-banner.severity-info {
    background: rgba(56, 139, 253, 0.1);
    border-bottom-color: rgba(56, 139, 253, 0.3);
    color: #58a6ff;
  }

  .error-banner svg {
    flex-shrink: 0;
  }

  .error-banner span {
    flex: 1;
  }

  .retry-btn {
    padding: 4px 10px;
    background: rgba(248, 81, 73, 0.15);
    border: 1px solid rgba(248, 81, 73, 0.4);
    border-radius: 4px;
    color: #f85149;
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    flex-shrink: 0;
  }

  .retry-btn:hover {
    background: rgba(248, 81, 73, 0.25);
  }

  .error-banner.severity-warning .retry-btn {
    background: rgba(210, 153, 34, 0.15);
    border-color: rgba(210, 153, 34, 0.4);
    color: #d29922;
  }

  .error-banner.severity-warning .retry-btn:hover {
    background: rgba(210, 153, 34, 0.25);
  }

  .dismiss-btn {
    padding: 4px;
    background: none;
    border: none;
    color: #f85149;
    cursor: pointer;
    border-radius: 4px;
    opacity: 0.7;
    transition: opacity 0.15s;
    flex-shrink: 0;
  }

  .dismiss-btn:hover {
    opacity: 1;
    background: rgba(248, 81, 73, 0.2);
  }

  .error-banner.severity-warning .dismiss-btn {
    color: #d29922;
  }

  .error-banner.severity-warning .dismiss-btn:hover {
    background: rgba(210, 153, 34, 0.2);
  }

  .error-banner.severity-info .dismiss-btn {
    color: #58a6ff;
  }

  .error-banner.severity-info .dismiss-btn:hover {
    background: rgba(56, 139, 253, 0.2);
  }

  .search-help-btn {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    border: 1px solid #555;
    background: #2a2a3a;
    color: #888;
    font-size: 0.85rem;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .search-help-btn:hover {
    border-color: #7c3aed;
    color: #7c3aed;
  }

  /* Mobile responsive styles */
  .hamburger {
    display: none;
    flex-direction: column;
    gap: 4px;
    padding: 8px;
    background: none;
    border: 1px solid #30363d;
    border-radius: 4px;
    cursor: pointer;
    flex-shrink: 0;
  }

  .hamburger-line {
    display: block;
    width: 20px;
    height: 2px;
    background: #c9d1d9;
    transition: transform 0.2s;
  }

  .sidebar-backdrop {
    display: none;
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    z-index: 99;
  }

  .sidebar-backdrop.visible {
    display: block;
  }

  @media (max-width: 768px) {
    .hamburger {
      display: flex;
    }

    .sidebar {
      position: fixed;
      left: -280px;
      top: 0;
      height: 100vh;
      z-index: 100;
      transition: left 0.3s ease;
      background: #161b22;
    }

    .sidebar.mobile-open {
      left: 0;
    }

    .main-content {
      margin-left: 0 !important;
    }

    .patterns-aside {
      display: none;
    }

    .header-actions {
      gap: 4px;
    }

    .nav-tabs button {
      padding: 8px 10px;
      font-size: 12px;
    }

    .nav-tabs button svg {
      display: none;
    }
  }

  @media (max-width: 480px) {
    header {
      padding: 8px 12px;
      gap: 8px;
    }

    .logo span {
      font-size: 1rem;
    }

    .logo svg {
      width: 24px;
      height: 24px;
    }

    .stats-bar {
      flex-wrap: wrap;
      gap: 4px;
      padding: 6px 12px;
    }

    .nav-tabs {
      padding: 2px;
    }

    .nav-tabs button {
      padding: 6px 8px;
      font-size: 11px;
    }

    .btn {
      padding: 6px 10px;
      font-size: 12px;
    }

    .user-menu {
      gap: 4px;
    }

    .user-name {
      display: none;
    }
  }

  /* Trial banner */
  .trial-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 20px;
    background: rgba(210, 153, 34, 0.1);
    border-bottom: 1px solid rgba(210, 153, 34, 0.3);
    color: #d29922;
    font-size: 13px;
  }

  .trial-banner svg {
    flex-shrink: 0;
  }

  .trial-banner span {
    flex: 1;
  }

  .trial-upgrade-btn {
    padding: 4px 12px;
    background: rgba(210, 153, 34, 0.15);
    border: 1px solid rgba(210, 153, 34, 0.4);
    border-radius: 6px;
    color: #d29922;
    font-size: 12px;
    font-weight: 500;
    text-decoration: none;
    transition: all 0.15s;
    flex-shrink: 0;
  }

  .trial-upgrade-btn:hover {
    background: rgba(210, 153, 34, 0.25);
    color: #e3b341;
  }

  .plan-badge.trial {
    background: rgba(210, 153, 34, 0.15);
    color: #d29922;
  }
</style>
