<!--
  LazyRoute Component
  Renders a route component loaded on demand via dynamic import().

  The loader promise is memoized per loader function, so navigating away and
  back re-uses the already-fetched chunk instead of flashing the spinner again.

  Usage:
  <LazyRoute loader={() => import('../AnalyticsPage.svelte')} name="Analytics" />
-->
<script module>
  // Module-level cache: loader fn -> import promise.
  // Without this, every re-render would call loader() again and produce a
  // fresh promise identity, sending {#await} back into its pending branch.
  const cache = new Map();

  function load(loader) {
    if (!cache.has(loader)) {
      cache.set(loader, loader());
    }
    return cache.get(loader);
  }

  function reload(loader) {
    // Drop the rejected promise so a retry actually re-requests the chunk.
    cache.delete(loader);
    return load(loader);
  }
</script>

<script>
  import LoadingSpinner from './LoadingSpinner.svelte';
  import Icon from './Icon.svelte';
  import { alertCircle } from './icons.js';

  let {
    /** Function returning a dynamic import() promise for the page component */
    loader,
    /** Human-readable route name, used in loading/error copy */
    name = 'page',
  } = $props();

  // Reassignable $derived: recomputes when `loader` changes, but retry() can
  // override it in place — the same contract the old reactive `promise` statement had.
  let promise = $derived(load(loader));

  function retry() {
    promise = reload(loader);
  }
</script>

{#await promise}
  <div class="lazy-route lazy-route-loading">
    <LoadingSpinner size="lg" variant="primary" centered label="Loading {name}..." />
  </div>
{:then module}
  {@const Page = module.default}
  <Page />
{:catch}
  <div class="lazy-route lazy-route-error" role="alert">
    <Icon icon={alertCircle} size={20} />
    <span>Failed to load the {name} page. Check your connection and try again.</span>
    <button class="retry-btn" onclick={retry}>Retry</button>
  </div>
{/await}

<style>
  .lazy-route {
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 1;
    padding: 48px 20px;
  }

  .lazy-route-loading {
    min-height: 240px;
  }

  .lazy-route-error {
    gap: 10px;
    color: #f85149;
    font-size: 13px;
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
</style>
