/**
 * Erasing a stored write-only secret.
 *
 * Write-only fields (ClickHouse password, bot tokens, webhook URLs, S3 keys)
 * are never sent back by GET — the API only reports whether one is set. The
 * forms therefore post them back EMPTY, and empty means "left untouched", so
 * there is no value the user can type that means "delete what you saved".
 *
 * The server's answer is an explicit instruction alongside the field:
 *
 *   { "bot_token": "", "clear_bot_token": true }
 *
 * Only `true` is an instruction; `clear_x: false` is a no-op, so a disarmed
 * checkbox must be omitted entirely rather than sent as false. Two more server
 * rules shape the callers:
 *
 *   400 "Cannot clear and set the same field" — clear_x plus a NON-blank x.
 *        Callers blank the input while the removal is armed, so the pair can
 *        never be produced by the UI; the message is still surfaced, never
 *        swallowed, in case some other path produces it.
 *   409 from_env — the environment owns the key. <ClearSecretToggle> disables
 *        itself on `envLocked` for exactly this reason.
 *
 * On success the response carries `cleared`: the section-relative keys that
 * were actually erased ('password', 'telegram.bot_token', 's3_access_key'),
 * or an empty array. That array — not the request — is what the user is told
 * about, because the server is the authority on what was removed.
 *
 * Lives here rather than in each settings page because five endpoints across
 * three panels speak this protocol and a copy per panel is how they drift.
 */

/**
 * Human names for the secrets, keyed exactly as the server reports them in
 * `cleared` (section-relative, dotted inside the notifications section).
 */
export const SECRET_LABELS = {
  // PUT /settings/clickhouse
  password: 'Password',
  // PUT /settings/notifications/<channel>
  'telegram.bot_token': 'Bot token',
  'telegram.chat_id': 'Chat ID',
  'slack.webhook_url': 'Webhook URL',
  'webhook.url': 'Webhook URL',
  'webhook.auth_token': 'Auth token',
  // PUT /backup/s3
  s3_access_key: 'Access key ID',
  s3_secret_key: 'Secret access key',
};

/**
 * Display name for a secret key.
 *
 * Falls back to a humanized last segment so a key the server learns to clear
 * before this table is updated still reads as words, never as a raw
 * identifier.
 *
 * @param {string} key section-relative key, e.g. 'telegram.bot_token'
 * @returns {string}
 */
export function secretLabel(key) {
  if (!key || typeof key !== 'string') return 'Saved value';
  if (SECRET_LABELS[key]) return SECRET_LABELS[key];

  const field = key.split('.').pop().replace(/_/g, ' ').trim();
  if (!field) return 'Saved value';
  return field.charAt(0).toUpperCase() + field.slice(1);
}

/** 'a', 'a and b', 'a, b, and c' */
function joinLabels(items) {
  if (items.length <= 1) return items[0] ?? '';
  if (items.length === 2) return `${items[0]} and ${items[1]}`;
  return `${items.slice(0, -1).join(', ')}, and ${items[items.length - 1]}`;
}

/** Armed keys, from either an array of keys or a { key: boolean } map. */
function armedKeys(pending) {
  if (Array.isArray(pending)) return pending.filter(Boolean);
  if (!pending || typeof pending !== 'object') return [];
  return Object.entries(pending)
    .filter(([, armed]) => armed)
    .map(([key]) => key);
}

/**
 * Request fragment for the armed removals: `{ clear_bot_token: true }`.
 *
 * The channel prefix is dropped because each channel has its OWN endpoint —
 * the body of PUT /settings/notifications/telegram says `clear_bot_token`,
 * not `clear_telegram.bot_token`. Disarmed keys are omitted rather than sent
 * as false, so nothing about the request even hints at a field the user did
 * not tick.
 *
 * @param {string[]|Record<string, boolean>} pending
 * @returns {Record<string, true>}
 */
export function clearFlags(pending) {
  const out = {};
  for (const key of armedKeys(pending)) {
    out[`clear_${key.split('.').pop()}`] = true;
  }
  return out;
}

/**
 * What to tell the user after a save, from the server's `cleared` array.
 *
 * Returns '' when nothing was erased — including for a server that predates
 * the field — which lets call sites write
 * `toastSuccess(describeCleared(data.cleared) || 'Settings saved')`.
 *
 * @param {string[]|undefined} cleared
 * @returns {string}
 */
export function describeCleared(cleared) {
  const keys = Array.isArray(cleared) ? cleared.filter(Boolean) : [];
  if (!keys.length) return '';
  return `${joinLabels(keys.map(secretLabel))} removed`;
}

/** Confirmation dialog title for the pending removals. */
export function clearConfirmTitle(keys) {
  return armedKeys(keys).length > 1 ? 'Remove saved secrets?' : 'Remove saved secret?';
}

/**
 * Confirmation dialog body. Names every secret about to go, because "are you
 * sure?" without the list is how the wrong one gets erased.
 */
export function clearConfirmMessage(keys) {
  const labels = armedKeys(keys).map(secretLabel);
  if (!labels.length) return 'Save these settings?';

  const plural = labels.length > 1;
  return `${joinLabels(labels)} will be deleted from the server when you save. `
    + `This cannot be undone — ${plural ? 'the values' : 'the value'} would have to be entered again.`;
}
