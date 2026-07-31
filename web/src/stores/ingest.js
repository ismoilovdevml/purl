/**
 * Purl - Ingest state
 *
 * Answers exactly one question: has this Purl instance EVER received a log
 * line? That is what separates "your filter matched nothing" from "you have
 * not connected a source yet" — two empty states that need completely
 * different advice, and which the UI used to conflate into
 * "Try adjusting your search or time range".
 *
 * Backend contract (already live, no new endpoint):
 *   GET /api/stats -> { "total_logs": 134501, ... }
 * `total_logs` is the unfiltered lifetime row count, so it is independent of
 * the current query, time range and selected cluster.
 */

import { writable, derived, get } from 'svelte/store';
import { api } from '../utils/api.js';

/** Lifetime log count. `null` while unknown (not fetched, or the call failed). */
export const totalLogsEver = writable(null);

/** True while the first/next /api/stats call is in flight. */
export const ingestStateLoading = writable(false);

/**
 * `true`  — logs have arrived at some point, so an empty result is a filter problem.
 * `false` — nothing has ever been ingested, so the user needs onboarding.
 * `null`  — not known yet; render the neutral empty state, never the onboarding one.
 *
 * Staying `null` on failure is deliberate: telling a user with 10M logs that
 * they have never sent one is worse than saying nothing.
 */
export const hasEverIngested = derived(totalLogsEver, ($n) =>
  $n === null ? null : $n > 0
);

let inflight = null;

/**
 * Fetch the lifetime count. Cheap and cached: once we know logs exist the
 * answer can never flip back, so repeat calls are skipped unless forced.
 *
 * Never throws — callers use this to decide which empty state to draw, and a
 * failed probe must not break the page that is already rendering.
 *
 * @param {{ force?: boolean }} [options]
 * @returns {Promise<number|null>} the lifetime count, or null if unknown
 */
export async function refreshIngestState({ force = false } = {}) {
  if (!force && get(totalLogsEver) > 0) return get(totalLogsEver);
  if (inflight) return inflight;

  ingestStateLoading.set(true);
  inflight = (async () => {
    try {
      const data = await api.get('/stats');
      const count = Number(data?.total_logs);
      const value = Number.isFinite(count) ? count : null;
      totalLogsEver.set(value);
      return value;
    } catch {
      // Unknown, not zero. hasEverIngested stays null and the caller falls
      // back to the neutral empty state.
      return get(totalLogsEver);
    } finally {
      inflight = null;
      ingestStateLoading.set(false);
    }
  })();

  return inflight;
}
