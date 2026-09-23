/**
 * Environment-pinned settings fields.
 *
 * Several settings endpoints return TWO different "from env" shapes:
 *
 *   from_env       — a single coarse flag for a whole panel. It only ever
 *                    tracked ONE variable (e.g. PURL_BACKUP_SCHEDULE_ENABLED),
 *                    so a field pinned by a different variable still rendered
 *                    editable.
 *   from_env_keys  — the per-key truth: { 'telegram.chat_id': 1, ... }, keyed
 *                    by the dotted name inside the section. (The LDAP/SAML/AI/
 *                    Redis endpoints ship the same map under `from_env`.)
 *
 * The server refuses to change an env-owned key — it answers 409 — so a field
 * the map marks must be disabled BEFORE the user types into it. Silently
 * disabling is not enough either: pair every locked control with <EnvBadge>,
 * whose tooltip carries ENV_LOCK_REASON, so the user knows why.
 *
 * Lives here rather than in each settings page because four pages need exactly
 * this lookup and a copy in each is how three of them ended up not having it.
 */

/** Why a control is disabled. Shown as the <EnvBadge> tooltip. */
export const ENV_LOCK_REASON =
  'Set by an environment variable on the server. Environment values override ' +
  'anything saved here, so this field can only be changed in your deployment ' +
  'config (.env, compose, Helm values) followed by a restart.';

/**
 * Is `key` pinned by the environment, according to a per-key map?
 *
 * Tolerates a missing/!object map on purpose: every caller reads it out of a
 * fetch response, and an older server (or a failed load) simply means "nothing
 * is pinned" — never a crash that blanks the settings page.
 *
 * @param {Record<string, unknown>|null|undefined} flags per-key map from the API
 * @param {string} key dotted key within the section, e.g. 'telegram.chat_id'
 * @returns {boolean}
 */
export function isEnvLocked(flags, key) {
  if (!flags || typeof flags !== 'object') return false;
  return !!flags[key];
}

/**
 * Options for a <Select> whose value may be pinned by the environment.
 *
 * An ENV-pinned value must be sent back verbatim (anything else is a 409), so
 * a page shows it as-is instead of normalising it. When it is not one of the
 * page's options it gets an option of its own, or the select would render
 * blank.
 * @param {Array<{ value: string, label: string }>} options - The page's options
 * @param {string | undefined} value - Current value
 * @returns {Array<{ value: string, label: string }>}
 */
export function optionsIncluding(options, value) {
  if (value === undefined || value === null || options.some((o) => o.value === value)) {
    return options;
  }
  return [...options, { value, label: String(value) }];
}
