<script>
  import { onMount, onDestroy, untrack } from 'svelte';
  import LoginPage from './components/LoginPage.svelte';
  import SearchHelp from './components/SearchHelp.svelte';
  import AppHeader from './components/app/AppHeader.svelte';
  import ErrorBanner from './components/app/ErrorBanner.svelte';
  import LogsView from './components/app/LogsView.svelte';
  import Toast from './components/ui/Toast.svelte';
  import LazyRoute from './components/ui/LazyRoute.svelte';
  import Icon from './components/ui/Icon.svelte';
  import { logo } from './components/ui/icons.js';
  import { PAGES, canAccessPage } from './utils/routes.js';
  import { query, timeRange, searchLogs } from './stores/logs.js';
  import { refreshInterval, defaultTimeRange } from './stores/settings.js';
  import {
    currentUser,
    checkAuth,
    logout,
    passwordChangeRequired,
    authState,
    serverRequiresAuth,
    k8sMode,
    AUTH_AUTHENTICATED,
  } from './stores/auth.js';
  import { fetchClusters } from './stores/cluster.js';
  import { initAI } from './stores/ai.js';

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

  const pageNames = Object.fromEntries(PAGES.map((p) => [p.id, p.label]));

  let savedSearchesRef = $state(null);
  let currentPage = $state('logs'); // 'logs' | 'analytics' | 'traces' | 'k8s' | 'query' | 'dashboards' | 'settings'
  let showSearchHelp = $state(false);
  let refreshIntervalId = null;
  let currentRefreshInterval = 30;
  let hasAppliedDefaultRange = false;
  let unsubscribeRefresh = null;
  let unsubscribeDefaultRange = null;

  // Boot asks "is there a session?" and must paint neither the dashboard nor
  // the login form until that has landed. 'loading' | 'ready'.
  let bootState = $state('loading');
  let initialDataLoaded = false;

  // Does this deployment demand a dashboard session? What the server told us
  // wins (/auth/me's auth_required, a 401 from a protected endpoint, or a
  // session we are already holding). If /auth/me could not answer at all,
  // demand credentials: falling through to "no auth needed" would render the
  // dashboard shell to an anonymous user with no route back to the login form
  // and a 401 on every request.
  const requiresLogin = $derived($serverRequiresAuth ?? true);

  // The forced password-change screen lives inside LoginPage, so an
  // authenticated-but-must-change user still belongs on it.
  const showLogin = $derived(requiresLogin && ($authState !== AUTH_AUTHENTICATED || $passwordChangeRequired));

  // Load the dashboard's data exactly when the dashboard actually becomes
  // visible: at boot for an open instance, or right after a successful sign-in.
  // Only `bootState` and `showLogin` are tracked; the load itself runs
  // untracked so the stores it reads and writes cannot re-arm this effect.
  $effect.pre(() => {
    const state = bootState;
    const hidden = showLogin;
    untrack(() => syncShellData(state, hidden));
  });

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

  // Mobile responsive state
  let mobileMenuOpen = $state(false);
  let isMobile = $state(false);

  function checkMobile() {
    isMobile = window.innerWidth < 768;
    if (!isMobile) mobileMenuOpen = false;
  }

  // Selected logs for bulk export (raw: replaced wholesale, rows are store data)
  let selectedLogs = $state.raw([]);
  // Export progress indicator for large exports
  let exportStatus = $state('');

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
    await checkAuth();

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

    // Last: flipping to 'ready' is what lets the shell paint, and `syncShellData`
    // picks up the initial fetch from here. `currentPage` must already be
    // resolved from the URL hash above before that happens.
    bootState = 'ready';

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
  });

  function handleHashChange() {
    // Only the first segment selects the page: `#settings/agents` routes to
    // settings, and the page itself reads the `/agents` suffix for its subtab.
    const hash = (window.location.hash.slice(1) || 'logs').split('/')[0];
    if (!PAGES.some((p) => p.id === hash)) return;
    if (!canAccessPage(hash, $currentUser, $k8sMode)) {
      currentPage = 'logs';
      window.location.hash = 'logs';
      return;
    }
    currentPage = hash;
  }

  function navigate(page) {
    if (!canAccessPage(page, $currentUser, $k8sMode)) return;
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

  function saveCurrentSearch() {
    savedSearchesRef?.openSaveModal($query, $timeRange);
  }
</script>

{#if bootState === 'loading'}
  <div class="app-loading">
    <Icon icon={logo} size={48} color="#58a6ff" label="Loading Purl" />
  </div>
{:else if showLogin}
  <!-- No onlogin handler: `syncShellData` reacts to the session state itself,
       so sign-in and open-instance boot take the exact same code path. -->
  <LoginPage />
{:else}
<main>
  <AppHeader
    {currentPage}
    {isMobile}
    bind:mobileMenuOpen
    {selectedLogs}
    bind:exportStatus
    onnavigate={navigate}
    onlogout={handleLogout}
    onsavesearch={saveCurrentSearch}
    onshowhelp={() => showSearchHelp = true}
  />

  {#if exportStatus === 'preparing'}
    <div class="info-banner" role="status">
      <span class="spinner spinner-sm"></span>
      <span>Preparing export...</span>
    </div>
  {/if}

  <ErrorBanner />

  {#if currentPage === 'logs'}
    <LogsView {isMobile} bind:mobileMenuOpen bind:selectedLogs bind:savedSearches={savedSearchesRef} />
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

  .app-loading {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100vh;
    background: #0d1117;
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
</style>
