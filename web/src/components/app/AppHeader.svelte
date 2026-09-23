<!--
  AppHeader
  The sticky top bar: mobile menu toggle, logo, page tabs, the signed-in user,
  and — on the logs page only — the logs toolbar.
-->
<script>
  import Icon from '../ui/Icon.svelte';
  import LogsToolbar from './LogsToolbar.svelte';
  import {
    logo,
    fileText,
    lineChart,
    activity,
    layers,
    code,
    grid,
    settings as settingsIcon,
  } from '../ui/icons.js';
  import { currentUser, k8sMode } from '../../stores/auth.js';
  import { PAGES, canAccessPage } from '../../utils/routes.js';

  /**
   * @type {{
   *   currentPage: string,
   *   isMobile: boolean,
   *   mobileMenuOpen?: boolean,
   *   selectedLogs: Array<Record<string, any>>,
   *   exportStatus?: string,
   *   onnavigate: (page: string) => void,
   *   onlogout: () => void,
   *   onsavesearch: () => void,
   *   onshowhelp: () => void,
   * }}
   */
  let {
    currentPage,
    isMobile,
    mobileMenuOpen = $bindable(false),
    selectedLogs,
    exportStatus = $bindable(''),
    onnavigate,
    onlogout,
    onsavesearch,
    onshowhelp,
  } = $props();

  const TAB_ICONS = {
    logs: fileText,
    analytics: lineChart,
    traces: activity,
    k8s: layers,
    query: code,
    dashboards: grid,
    settings: settingsIcon,
  };

  const visiblePages = $derived(PAGES.filter((p) => canAccessPage(p.id, $currentUser, $k8sMode)));
</script>

<header>
  {#if isMobile}
    <button class="hamburger" onclick={() => mobileMenuOpen = !mobileMenuOpen} aria-label="Toggle menu">
      <span class="hamburger-line"></span>
      <span class="hamburger-line"></span>
      <span class="hamburger-line"></span>
    </button>
  {/if}
  <button class="logo" onclick={() => onnavigate('logs')}>
    <Icon icon={logo} size={32} />
    <span>Purl</span>
  </button>

  <nav class="nav-tabs">
    {#each visiblePages as page (page.id)}
      <button
        class:active={currentPage === page.id}
        onclick={() => onnavigate(page.id)}
      >
        <Icon icon={TAB_ICONS[page.id]} size={16} />
        {page.label}
      </button>
    {/each}
  </nav>

  {#if $currentUser}
    <div class="user-menu">
      <span class="user-name">{$currentUser.username}</span>
      <button class="btn btn-sm" onclick={onlogout}>Logout</button>
    </div>
  {/if}

  {#if currentPage === 'logs'}
    <LogsToolbar {selectedLogs} bind:exportStatus {onsavesearch} {onshowhelp} />
  {/if}
</header>

<style>
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

  /* Was `.btn` + `.btn-sm` when App held the toolbar's `.btn` rule too; the
     layout half of `.btn` is folded in here so the button looks the same. */
  .btn-sm {
    display: flex;
    align-items: center;
    gap: 6px;
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

  @media (max-width: 768px) {
    .hamburger {
      display: flex;
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

    .nav-tabs {
      padding: 2px;
    }

    .nav-tabs button {
      padding: 6px 8px;
      font-size: 11px;
    }

    .btn-sm {
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
</style>
