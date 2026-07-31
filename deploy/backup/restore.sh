#!/usr/bin/env bash
# Purl — ClickHouse Restore (native RESTORE, idempotent)
#
# Restores a backup produced by backup.sh using ClickHouse's native
# `RESTORE ... FROM S3(...)` (or File()). Runs entirely server-side and streams.
#
# IDEMPOTENCY (running restore twice must NOT duplicate rows):
#   * Full-database mode restores into a FRESH, empty database. The live
#     database is first renamed aside (or dropped with --replace), so RESTORE
#     always targets an empty target. ClickHouse itself refuses to restore into
#     a non-empty table (error 608 CANNOT_RESTORE_TABLE) unless
#     allow_non_empty_tables=true — which this script NEVER sets. Appending, and
#     therefore duplication, is impossible by construction.
#   * Per-table mode (--tables) restores each table into a fresh
#     <table>_restore_staging, then does an atomic `EXCHANGE TABLES`. The old
#     table is replaced wholesale, never appended to. The materialized view that
#     feeds log_patterns stays attached to the (name-stable) logs table.
#
# Usage:
#   ./restore.sh purl_backup_20260714_120000
#   ./restore.sh purl_backup_20260714_120000 --replace
#   ./restore.sh purl_backup_20260714_120000 --tables logs,alerts
#
# Options:
#   --replace          Drop the existing database before restore (no aside copy).
#   --tables t1,t2     Restore only these tables (staging + atomic EXCHANGE).
#   --purge-aside      In full mode, drop the renamed-aside DB after success.
#
# Connection + destination env vars: identical to backup.sh.

set -euo pipefail

# -------------------------------------------
# Configuration
# -------------------------------------------
CH_HOST="${PURL_CLICKHOUSE_HOST:-${CLICKHOUSE_HOST:-clickhouse}}"
CH_HTTP_PORT="${PURL_CLICKHOUSE_HTTP_PORT:-${CLICKHOUSE_PORT:-8123}}"
CH_NATIVE_PORT="${PURL_CLICKHOUSE_NATIVE_PORT:-9000}"
CH_DB="${PURL_CLICKHOUSE_DATABASE:-${CLICKHOUSE_DB:-purl}}"
CH_USER="${PURL_CLICKHOUSE_USER:-${CLICKHOUSE_USER:-default}}"
CH_PASSWORD="${PURL_CLICKHOUSE_PASSWORD:-${CLICKHOUSE_PASSWORD:-}}"

S3_ENABLED="${PURL_BACKUP_S3_ENABLED:-0}"
S3_BUCKET="${PURL_BACKUP_S3_BUCKET:-}"
S3_REGION="${PURL_BACKUP_S3_REGION:-us-east-1}"
S3_PREFIX="${PURL_BACKUP_S3_PREFIX:-purl-backups/}"
S3_ENDPOINT="${PURL_BACKUP_S3_ENDPOINT:-}"
S3_ACCESS_KEY="${AWS_ACCESS_KEY_ID:-}"
S3_SECRET_KEY="${AWS_SECRET_ACCESS_KEY:-}"

# -------------------------------------------
# Logging helpers
# -------------------------------------------
log()   { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# -------------------------------------------
# Argument parsing
# -------------------------------------------
BACKUP_NAME=""
REPLACE=0
PURGE_ASIDE=0
TABLES_CSV=""

while [ $# -gt 0 ]; do
    case "$1" in
        --replace)      REPLACE=1; shift ;;
        --purge-aside)  PURGE_ASIDE=1; shift ;;
        --tables)       TABLES_CSV="${2:-}"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)
            error "Unknown option: $1"; exit 1 ;;
        *)
            if [ -z "${BACKUP_NAME}" ]; then BACKUP_NAME="$1"; else error "Unexpected arg: $1"; exit 1; fi
            shift ;;
    esac
done

if [ -z "${BACKUP_NAME}" ]; then
    error "Usage: $0 <backup-name> [--replace] [--tables t1,t2] [--purge-aside]"
    exit 1
fi

# -------------------------------------------
# ClickHouse query runner (see backup.sh)
# -------------------------------------------
ch_query() {
    local sql="$1"
    if command -v clickhouse-client >/dev/null 2>&1; then
        clickhouse-client \
            --host "${CH_HOST}" --port "${CH_NATIVE_PORT}" \
            --user "${CH_USER}" --password "${CH_PASSWORD}" \
            --query "${sql}"
    else
        curl -sS -m 0 --fail-with-body \
            -H "X-ClickHouse-User: ${CH_USER}" \
            -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
            "http://${CH_HOST}:${CH_HTTP_PORT}/" \
            --data-binary "${sql}"
    fi
}

# -------------------------------------------
# Build the SOURCE clause (must match backup.sh exactly)
# -------------------------------------------
build_source() {
    if [ "${S3_ENABLED}" = "1" ]; then
        if [ -z "${S3_BUCKET}" ] || [ -z "${S3_ACCESS_KEY}" ] || [ -z "${S3_SECRET_KEY}" ]; then
            error "S3 restore enabled but PURL_BACKUP_S3_BUCKET / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY missing"
            exit 1
        fi
        local base prefix url
        if [ -n "${S3_ENDPOINT}" ]; then
            base="${S3_ENDPOINT%/}/${S3_BUCKET}"
        else
            base="https://${S3_BUCKET}.s3.${S3_REGION}.amazonaws.com"
        fi
        prefix="${S3_PREFIX#/}"
        [ -n "${prefix}" ] && prefix="${prefix%/}/"
        url="${base}/${prefix}${BACKUP_NAME}"
        SRC="S3('${url}', '${S3_ACCESS_KEY}', '${S3_SECRET_KEY}')"
        SRC_DISPLAY="S3('${url}', '***', '***')"
    else
        SRC="File('${BACKUP_NAME}.zip')"
        SRC_DISPLAY="${SRC}"
    fi
}

build_source

log "Starting Purl restore"
log "ClickHouse: ${CH_HOST} (http:${CH_HTTP_PORT} / native:${CH_NATIVE_PORT}) db=${CH_DB}"
log "Source    : ${SRC_DISPLAY}"

# =========================================================
# Per-table restore: staging + atomic EXCHANGE (idempotent)
# =========================================================
if [ -n "${TABLES_CSV}" ]; then
    IFS=',' read -r -a TBLS <<< "${TABLES_CSV}"
    FAILED=0
    for raw in "${TBLS[@]}"; do
        t="$(echo "${raw}" | tr -d '[:space:]')"
        [ -z "${t}" ] && continue
        staging="${t}_restore_staging"
        log "Restoring table ${CH_DB}.${t} via staging ${CH_DB}.${staging}"

        ch_query "DROP TABLE IF EXISTS ${CH_DB}.${staging} SYNC" >/dev/null 2>&1 || true

        if ! OUT="$(ch_query "RESTORE TABLE ${CH_DB}.${t} AS ${CH_DB}.${staging} FROM ${SRC}" 2>&1)"; then
            error "RESTORE into staging failed for ${t}: ${OUT}"
            ch_query "DROP TABLE IF EXISTS ${CH_DB}.${staging} SYNC" >/dev/null 2>&1 || true
            FAILED=$((FAILED + 1)); continue
        fi

        # Atomic swap: live table is replaced wholesale, never appended to.
        if ! OUT="$(ch_query "EXCHANGE TABLES ${CH_DB}.${t} AND ${CH_DB}.${staging}" 2>&1)"; then
            error "EXCHANGE failed for ${t}: ${OUT}"
            ch_query "DROP TABLE IF EXISTS ${CH_DB}.${staging} SYNC" >/dev/null 2>&1 || true
            FAILED=$((FAILED + 1)); continue
        fi

        ch_query "DROP TABLE IF EXISTS ${CH_DB}.${staging} SYNC" >/dev/null 2>&1 || true
        rows="$(ch_query "SELECT count() FROM ${CH_DB}.${t}" 2>/dev/null | tr -d '[:space:]')"
        log "  -> ${t}: ${rows} rows (atomic EXCHANGE done)"
    done

    if [ "${FAILED}" -gt 0 ]; then
        error "Restore completed with ${FAILED} table error(s)"; exit 1
    fi
    log "Table restore completed successfully"
    exit 0
fi

# =========================================================
# Full-database restore: rename-aside (or --replace) + RESTORE (idempotent)
# =========================================================
DB_EXISTS="$(ch_query "EXISTS DATABASE ${CH_DB}" 2>/dev/null | tr -d '[:space:]')"

ASIDE=""
if [ "${DB_EXISTS}" = "1" ]; then
    if [ "${REPLACE}" = "1" ]; then
        log "--replace: dropping existing database ${CH_DB}"
        ch_query "DROP DATABASE IF EXISTS ${CH_DB} SYNC" >/dev/null
    else
        ASIDE="${CH_DB}_pre_restore_$(date -u +%Y%m%d_%H%M%S)"
        log "Renaming live database ${CH_DB} aside to ${ASIDE}"
        ch_query "RENAME DATABASE ${CH_DB} TO ${ASIDE}" >/dev/null
    fi
fi

log "Restoring DATABASE ${CH_DB} (fresh, empty target)…"
if ! OUT="$(ch_query "RESTORE DATABASE ${CH_DB} FROM ${SRC}" 2>&1)"; then
    error "RESTORE DATABASE failed: ${OUT}"
    if [ -n "${ASIDE}" ]; then
        error "Rolling back: renaming ${ASIDE} back to ${CH_DB}"
        ch_query "DROP DATABASE IF EXISTS ${CH_DB} SYNC" >/dev/null 2>&1 || true
        ch_query "RENAME DATABASE ${ASIDE} TO ${CH_DB}" >/dev/null 2>&1 || true
    fi
    exit 1
fi
log "ClickHouse response: ${OUT}"

if [ -n "${ASIDE}" ]; then
    if [ "${PURGE_ASIDE}" = "1" ]; then
        log "--purge-aside: dropping ${ASIDE}"
        ch_query "DROP DATABASE IF EXISTS ${ASIDE} SYNC" >/dev/null 2>&1 || true
    else
        log "Previous database kept as ${ASIDE}. Verify the restore, then drop it:"
        log "  clickhouse-client --query \"DROP DATABASE ${ASIDE} SYNC\""
    fi
fi

log "Restore completed successfully from: ${BACKUP_NAME}"

# ---------------------------------------------------------
# /app/config (dashboard users, license key, settings.json)
#
# The Helm backup CronJob (backup.includeConfig=true) tars the config volume
# into <db>.purl_config_archive so it travels inside the same BACKUP. Logs
# alone are not a recovery: without this you restore every log line and still
# cannot log in.
# ---------------------------------------------------------
if [ "$(ch_query "EXISTS TABLE ${CH_DB}.purl_config_archive" 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
    SNAPSHOT="$(ch_query "SELECT max(captured_at) FROM ${CH_DB}.purl_config_archive" 2>/dev/null | tr -d '[:space:]')"
    log ""
    log "This backup also contains a /app/config snapshot (${SNAPSHOT})."
    log "Restore it into the running Purl pod's config volume with:"
    log ""
    log "  clickhouse-client --host ${CH_HOST} --port ${CH_NATIVE_PORT} \\"
    log "    --user ${CH_USER} --password \"\$PURL_CLICKHOUSE_PASSWORD\" \\"
    log "    --query \"SELECT archive FROM ${CH_DB}.purl_config_archive ORDER BY captured_at DESC LIMIT 1 FORMAT RawBLOB\" \\"
    log "    > /tmp/purl-config.tar.gz"
    log "  kubectl -n <ns> cp /tmp/purl-config.tar.gz <purl-pod>:/tmp/purl-config.tar.gz"
    log "  kubectl -n <ns> exec <purl-pod> -- tar xzf /tmp/purl-config.tar.gz -C /app/config"
    log "  kubectl -n <ns> rollout restart deployment/<purl-release>"
fi
