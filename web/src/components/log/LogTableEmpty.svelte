<!--
  LogTableEmpty
  What the log table shows when a search returned no rows. Three very
  different situations share the "zero rows" outcome:

  - `$searchError`: the last search never produced a result set at all
    (rejected query, server down) — saying "no logs found" there would report
    a broken query as an answer.
  - `$hasEverIngested === false`: this instance has never received a single
    line, so search advice is useless and the user needs onboarding.
  - `true` (and `null` = not known) keep the original meaning — never guess
    "you have no logs" on an unknown probe.
-->
<svelte:options runes />

<script>
  import { error as searchError, searchLogs } from '../../stores/logs.js';
  import { hasEverIngested } from '../../stores/ingest.js';
  import EmptyState from '../ui/EmptyState.svelte';
  import Button from '../ui/Button.svelte';
  import IngestSnippet from '../onboarding/IngestSnippet.svelte';
  import { alertCircle, box, search } from '../ui/icons.js';
</script>

{#if $searchError}
  <EmptyState icon={alertCircle} title="Search failed" tone="error">
    {#snippet description()}<span>{$searchError}</span>{/snippet}
    {#snippet actions()}
      <Button size="sm" onclick={searchLogs}>Retry search</Button>
    {/snippet}
  </EmptyState>
{:else if $hasEverIngested === false}
  <EmptyState icon={box} title="No logs yet" tone="accent">
    {#snippet description()}
      <span>
        Purl has not received any logs from this instance yet. Point a log source at it and
        they will show up here.
      </span>
    {/snippet}
    {#snippet actions()}
      <a class="onboard-btn" href="#settings/agents">Set up a log source</a>
      <a
        class="onboard-link"
        href="https://purlogs.com/docs"
        target="_blank"
        rel="noopener noreferrer"
      >Read the docs</a>
    {/snippet}
    {#snippet extra()}
      <IngestSnippet />
    {/snippet}
  </EmptyState>
{:else}
  <EmptyState icon={search} title="No logs found">
    Try adjusting your search or time range.
  </EmptyState>
{/if}

<style>
  /* Onboarding empty state (never-ingested instance) */
  .onboard-btn {
    display: inline-flex;
    align-items: center;
    padding: 6px 14px;
    background: var(--color-primary);
    border: 1px solid var(--color-primary);
    border-radius: var(--radius-sm);
    color: var(--bg-primary);
    font-size: var(--text-sm);
    font-weight: 600;
    text-decoration: none;
  }

  .onboard-btn:hover {
    filter: brightness(1.1);
  }

  .onboard-link {
    display: inline-flex;
    align-items: center;
    padding: 6px 14px;
    background: transparent;
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: var(--text-sm);
    text-decoration: none;
  }

  .onboard-link:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }
</style>
