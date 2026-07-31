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
  import LoginPage from './components/LoginPage.svelte';
  import SearchHelp from './components/SearchHelp.svelte';
  import Toast from './components/ui/Toast.svelte';
  import ClusterSelector from './components/ui/ClusterSelector.svelte';
  import LazyRoute from './components/ui/LazyRoute.svelte';
  import Icon from './components/ui/Icon.svelte';
  import {
    logo,
    fileText,
    lineChart,
    activity,
    layers,
    code,
    grid,
    lock,
    settings as settingsIcon,
    chevronDown,
    braces,
    save,
    clock,
    alertCircleSolid,
    close,
  } from './components/ui/icons.js';

  // Route-level code splitting: each non-default page is its own chunk, fetched
  // on first navigation. The `logs` page is intentionally eager — it is the
  // default route, so lazy-loading it would only add a round-trip before first
  // paint. Loaders are declared once at module scope so their identity is
  // stable and LazyRoute can memoize the resulting import promise.
  const pageLoaders = {
    analytics: () => import('./components/AnalyticsPage.svelte'),
    traces: () => import('./components/TracesPage.svelte'),
    k8s: () => import('./components/K8sPage.svelte'),
    query: () => import('./components/QueryPage.svelte'),
    dashboards: () => import('./components/dashboard/DashboardPage.svelte'),
    settings: () => import('./components/settings/SettingsPage.svelte'),
  };

  const pageNames = {
    analytics: 'Analytics',
    traces: 'Traces',
    k8s: 'K8s',
    query: 'Query',
    dashboards: 'Dashboards',
    settings: 'Settings',
  };
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
  import { fetchLicense, hasFeature, currentPlan, isPaidPlan, isTrialPlan, trialDaysRemaining, licenseFeatures, k8sMode, planKnown } from './stores/license.js';
  import {
    currentUser,
    checkAuth,
    logout,
    passwordChangeRequired,
    authState,
    serverRequiresAuth,
    AUTH_AUTHENTICATED,
  } from './stores/auth.js';
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

  // Boot asks two questions — "which plan is this?" and "is there a session?" —
  // and must paint neither the dashboard nor the login form until BOTH have
  // landed. 'loading' | 'ready'.
  let bootState = 'loading';
  let initialDataLoaded = false;

  // Does this deployment demand a dashboard session?
  //   1. What the server told us always wins: a 401 from a protected endpoint,
  //      or a session we are already holding.
  //   2. Otherwise fall back to the plan — paid/trial installs run with auth on.
  //   3. If the plan could not be determined at ALL (/license 401'd or errored),
  //      demand credentials. The previous code fell through to "no auth needed"
  //      here, which rendered the dashboard shell to an anonymous user with no
  //      route back to the login form and a 401 on every request.
  $: requiresLogin =
    $serverRequiresAuth !== null
      ? $serverRequiresAuth
      : $planKnown
        ? $isPaidPlan
        : true;

  // The forced password-change screen lives inside LoginPage, so an
  // authenticated-but-must-change user still belongs on it.
  $: showLogin = requiresLogin && ($authState !== AUTH_AUTHENTICATED || $passwordChangeRequired);

  // Load the dashboard's data exactly when the dashboard actually becomes
  // visible: at boot for an open instance, or right after a successful sign-in.
  // `initialDataLoaded` is read inside the function on purpose — referencing it
  // directly here would make this statement re-run on its own assignment.
  $: syncShellData(bootState, showLogin);

  function syncShellData(state, hidden) {
    if (state !== 'ready') return;
    if (hidden) {
      // Back at the login form: the next sign-in must refetch, not reuse the
      // previous user's data.
      initialDataLoaded = false;
      return;
    }
    if (initialDataLoaded) return;
    initialDataLoaded = true;
    loadInitialData();
  }

  async function loadInitialData() {
    fetchClusters();
    initAI();
    if (currentPage === 'logs') {
      await searchLogs();
    }
  }

  // Action menus (touch-friendly instead of hover-only)
  let actionsMenuOpen = false;
  let selectionMenuOpen = false;
  let actionsMenuEl;
  let selectionMenuEl;

  // Route dashboards gating through hasFeature so enterprise-bypass and the
  // custom_dashboards → dashboards alias apply (matches backend has_feature).
  // Referencing the stores keeps this reactive to license changes.
  $: hasDashboards = ($currentPlan, $licenseFeatures, hasFeature('dashboards'));

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

  // Which `$error` value the user (or the auto-dismiss timer) already sent away.
  // This is the loop-breaker. The banner and the `error` store have different
  // lifetimes on purpose — the store must stay set so LogTable knows its rows
  // are not an answer to the current query — so dismissal cannot be expressed by
  // clearing the store. Instead the sync below remembers what was dismissed and
  // refuses to raise it a second time. Reset whenever the store goes null (i.e.
  // a new search started), so the same message from a NEW failure shows again.
  let dismissedMessage = null;

  // Sync the logs store error into the local banner (retry defaults to
  // searchLogs). Deliberately a single function call: the reactive statement's
  // only tracked dependency is `$error`, so the writes this makes to
  // `errorState`/`dismissedMessage` cannot re-trigger it. Reading `errorState`
  // directly in the statement is what previously made dismissal impossible —
  // clearError() wrote the tracked dependency, the pre-effect re-ran in the same
  // flush, `$error` was still set, and the banner was rebuilt before paint.
  $: syncBannerWithStoreError($error);

  function syncBannerWithStoreError(storeError) {
    if (storeError) {
      if (storeError === dismissedMessage) return;
      setError(storeError, searchLogs, 'error');
      return;
    }
    dismissedMessage = null;
    if (errorState.message && errorState.retryFn === searchLogs) clearError();
  }

  function setError(message, retryFn = null, severity = 'error') {
    // Avoid redundant re-renders: skip if the same error is already displayed
    if (errorState.message === message && errorState.severity === severity) return;
    if (errorDismissTimer) clearTimeout(errorDismissTimer);
    errorState = { message, retryFn, severity };
    // Auto-dismiss after 10 seconds
    errorDismissTimer = setTimeout(() => {
      dismissError();
    }, 10000);
  }

  // User-initiated (X button) or timer-initiated hide. Records the message so
  // the store→banner sync does not raise it again while `$error` still holds it.
  function dismissError() {
    if (errorState.message && errorState.message === $error) {
      dismissedMessage = errorState.message;
    }
    clearError();
  }

  // Hides the BANNER only. The `error` store is deliberately left alone: it is
  // also what tells the log table that the current rows are not an answer to the
  // current query, and that stays true after the banner is gone. The store is
  // cleared by the next search (searchLogs sets it to null on entry).
  function clearError() {
    if (errorDismissTimer) {
      clearTimeout(errorDismissTimer);
      errorDismissTimer = null;
    }
    errorState = { message: '', retryFn: null, severity: 'error' };
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
    window.location.hash = 'logs';
  }

  onMount(async () => {
    // Both are public endpoints answering independent questions, so they run in
    // parallel. checkAuth() is UNCONDITIONAL: making it depend on the license
    // plan meant a bad /license response skipped the session check entirely and
    // the app rendered as if authentication did not exist.
    await Promise.all([fetchLicense(), checkAuth()]);

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
    window.addEventListener('click', handleClickOutside, true);

    // Last: flipping to 'ready' is what lets the shell paint, and `syncShellData`
    // picks up the initial fetch from here. `currentPage` must already be
    // resolved from the URL hash above before that happens.
    bootState = 'ready';

    return () => {
      window.removeEventListener('hashchange', handleHashChange);
      window.removeEventListener('resize', checkMobile);
      window.removeEventListener('click', handleClickOutside, true);
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
    // Only the first segment selects the page: `#settings/agents` routes to
    // settings, and the page itself reads the `/agents` suffix for its subtab.
    const hash = (window.location.hash.slice(1) || 'logs').split('/')[0];
    if (['logs', 'analytics', 'traces', 'k8s', 'query', 'dashboards', 'settings'].includes(hash)) {
      if (hash === 'dashboards' && !hasDashboards) {
        currentPage = 'logs';
        window.location.hash = 'logs';
        toastWarning('Custom Dashboards requires a Pro or Enterprise license');
        return;
      }
      if ((hash === 'settings' || hash === 'analytics') && $currentUser?.role === 'viewer') {
        currentPage = 'logs';
        window.location.hash = 'logs';
        return;
      }
      if (hash === 'k8s' && !$k8sMode) {
        currentPage = 'logs';
        window.location.hash = 'logs';
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
    if ((page === 'settings' || page === 'analytics') && $currentUser?.role === 'viewer') {
      return;
    }
    if (page === 'k8s' && !$k8sMode) {
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
    const ids = event.detail?.selected || [];
    // Short-circuit empty selection to avoid reading $logs inside
    // a reactive tracking scope (dispatch from child reactive block)
    if (ids.length === 0) {
      if (selectedLogs.length === 0) return;
      selectedLogs = [];
      return;
    }
    const idSet = new Set(ids);
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

  function handleClickOutside(event) {
    const target = event.target;
    if (actionsMenuOpen && actionsMenuEl && !actionsMenuEl.contains(target)) {
      actionsMenuOpen = false;
    }
    if (selectionMenuOpen && selectionMenuEl && !selectionMenuEl.contains(target)) {
      selectionMenuOpen = false;
    }
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

{#if bootState === 'loading'}
  <div class="app-loading">
    <Icon icon={logo} size={48} color="#58a6ff" label="Loading Purl" />
  </div>
{:else if showLogin}
  <!-- No on:login handler: `syncShellData` reacts to the session state itself,
       so sign-in and open-instance boot take the exact same code path. -->
  <LoginPage />
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
      <Icon icon={logo} size={32} />
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
        <Icon icon={fileText} size={16} />
        Logs
      </button>
      {#if $currentUser?.role !== 'viewer'}
      <button
        class:active={currentPage === 'analytics'}
        on:click={() => navigate('analytics')}
      >
        <Icon icon={lineChart} size={16} />
        Analytics
      </button>
      {/if}
      <button
        class:active={currentPage === 'traces'}
        on:click={() => navigate('traces')}
      >
        <Icon icon={activity} size={16} />
        Traces
      </button>
      {#if $k8sMode}
      <button
        class:active={currentPage === 'k8s'}
        on:click={() => navigate('k8s')}
      >
        <Icon icon={layers} size={16} />
        K8s
      </button>
      {/if}
      <button
        class:active={currentPage === 'query'}
        on:click={() => navigate('query')}
      >
        <Icon icon={code} size={16} />
        Query
      </button>
      <button
        class:active={currentPage === 'dashboards'}
        class:locked={!hasDashboards}
        on:click={() => navigate('dashboards')}
      >
        <Icon icon={hasDashboards ? grid : lock} size={16} />
        Dashboards
        {#if !hasDashboards}
          <span class="pro-badge">Pro</span>
        {/if}
      </button>
      {#if $currentUser?.role !== 'viewer'}
      <button
        class:active={currentPage === 'settings'}
        on:click={() => navigate('settings')}
      >
        <Icon icon={settingsIcon} size={16} />
        Settings
      </button>
      {/if}
    </nav>

    {#if $currentUser}
      <div class="user-menu">
        <span class="user-name">{$currentUser.username}</span>
        <button class="btn btn-sm" on:click={handleLogout}>Logout</button>
      </div>
    {/if}

    {#if currentPage === 'logs'}
      <SearchBar bind:value={$query} on:search={handleSearch} />
      <button
        class="search-help-btn"
        on:click={() => showSearchHelp = true}
        title="Search syntax help"
        aria-label="Search syntax help"
      >?</button>

      <div class="header-actions">
        {#if $clusters.length > 0}
          <ClusterSelector on:change={handleClusterChange} />
        {/if}
        <TimeRangePicker value={$timeRange} on:change={handleTimeRangeChange} />

        {#if selectedLogs.length > 0}
          <div class="actions-dropdown" bind:this={selectionMenuEl}>
            <button
              class="btn btn-selected dropdown-trigger"
              aria-haspopup="menu"
              aria-expanded={selectionMenuOpen}
              on:click={() => selectionMenuOpen = !selectionMenuOpen}
            >
              Export Selected ({selectedLogs.length})
              <Icon icon={chevronDown} size={12} strokeWidth={3} />
            </button>
            <div class="dropdown-menu" class:open={selectionMenuOpen}>
              <button on:click={() => { exportCSV(selectedLogs); selectionMenuOpen = false; }}>
                <Icon icon={fileText} size={14} strokeWidth={2.5} />
                Export CSV
              </button>
              <button on:click={() => { exportJSON(selectedLogs); selectionMenuOpen = false; }}>
                <Icon icon={braces} size={14} strokeWidth={2.5} />
                Export JSON
              </button>
            </div>
          </div>
        {/if}

        <div class="actions-dropdown" bind:this={actionsMenuEl}>
          <button
            class="btn dropdown-trigger"
            aria-haspopup="menu"
            aria-expanded={actionsMenuOpen}
            on:click={() => actionsMenuOpen = !actionsMenuOpen}
          >
            Actions
            <Icon icon={chevronDown} size={12} strokeWidth={3} />
          </button>

          <div class="dropdown-menu" class:open={actionsMenuOpen}>
            <button on:click={() => { saveCurrentSearch(); actionsMenuOpen = false; }}>
              <Icon icon={save} size={14} strokeWidth={2.5} />
              Save Search
            </button>
            <div class="divider"></div>
            <button on:click={() => { exportCSV($logs); actionsMenuOpen = false; }} disabled={$logs.length === 0}>
              <Icon icon={fileText} size={14} strokeWidth={2.5} />
              Export CSV
            </button>
            <button on:click={() => { exportJSON($logs); actionsMenuOpen = false; }} disabled={$logs.length === 0}>
              <Icon icon={braces} size={14} strokeWidth={2.5} />
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
      <Icon icon={clock} size={16} />
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
      <Icon icon={alertCircleSolid} size={16} />
      <span>{errorState.message}</span>
      {#if errorState.retryFn}
        <button class="retry-btn" on:click={errorState.retryFn} aria-label="Retry">
          Retry
        </button>
      {/if}
      <button
        class="dismiss-btn"
        on:click={dismissError}
        aria-label="Dismiss error"
      >
        <Icon icon={close} size={14} strokeWidth={3} />
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
  {:else if pageLoaders[currentPage]}
    <LazyRoute loader={pageLoaders[currentPage]} name={pageNames[currentPage]} />
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

  /* :global — icons render inside <Icon>, so they carry that component's scope,
     not this one's. Every svg rule below is scoped by its parent class. */
  .nav-tabs button :global(svg) {
    opacity: 0.7;
  }

  .nav-tabs button.active :global(svg) {
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
    /* @keyframes spin lives in src/styles/animations.css (declared once).
       Svelte only rewrites keyframe names it finds declared in this component,
       so with no local block the name resolves to the global one. */
    animation: spin 0.8s linear infinite;
  }

  .spinner-sm {
    width: 12px;
    height: 12px;
    flex-shrink: 0;
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

  /* Hover support kept for desktop but click toggle controls visibility */
  /* Hover kept for desktop but visibility controlled via .open class */

  .dropdown-trigger {
    padding-right: 12px;
  }

  .dropdown-trigger :global(svg) {
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

  .dropdown-menu.open {
    display: block;
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

  .dropdown-menu button :global(svg) {
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

  .error-banner :global(svg) {
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

    .nav-tabs button :global(svg) {
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

    .logo :global(svg) {
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

  .trial-banner :global(svg) {
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
