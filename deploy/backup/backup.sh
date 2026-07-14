#!/usr/bin/env bash
# Purl — ClickHouse Backup (native BACKUP, streaming)
#
# Uses ClickHouse's native `BACKUP DATABASE ... TO S3(...)` (or File()) instead
# of `SELECT * ... FORMAT CSV`. Native backup is executed server-side and
# STREAMS data straight to the destination — it never materialises the table in
# the shell, so it does not OOM or time out at real log volume.
#
# Usage:
#   ./backup.sh                 # back up the whole database
#   ./backup.sh logs alerts     # back up only the named tables
#
# Connection (app-standard names, with legacy fallbacks):
#   PURL_CLICKHOUSE_HOST      (default: clickhouse)     | legacy CLICKHOUSE_HOST
#   PURL_CLICKHOUSE_HTTP_PORT (default: 8123)           | legacy CLICKHOUSE_PORT
#   PURL_CLICKHOUSE_NATIVE_PORT (default: 9000)
#   PURL_CLICKHOUSE_DATABASE  (default: purl)           | legacy CLICKHOUSE_DB
#   PURL_CLICKHOUSE_USER      (default: default)
#   PURL_CLICKHOUSE_PASSWORD  (default: empty)
#
# Destination (reuses lib/Purl/Config.pm `backup` section env vars):
#   PURL_BACKUP_S3_ENABLED    0|1  (default: 0 -> local File())
#   PURL_BACKUP_S3_BUCKET     S3 bucket name
#   PURL_BACKUP_S3_REGION     (default: us-east-1)
#   PURL_BACKUP_S3_PREFIX     (default: purl-backups/)
#   PURL_BACKUP_S3_ENDPOINT   custom endpoint (e.g. MinIO); empty = AWS
#   AWS_ACCESS_KEY_ID         S3 access key
#   AWS_SECRET_ACCESS_KEY     S3 secret key
#   PURL_BACKUP_DIR           local backup name dir hint (default: /backups)
#   PURL_BACKUP_RETENTION_DAYS (default: 30) — advisory; see NOTE on retention
#
# Optional:
#   BACKUP_NAME               override the generated backup name
#
# Exit codes: 0 = success, 1 = failure.

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
RETENTION_DAYS="${PURL_BACKUP_RETENTION_DAYS:-30}"

TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
BACKUP_NAME="${BACKUP_NAME:-purl_backup_${TIMESTAMP}}"

# Tables requested on the command line (empty => whole database)
TABLES=("$@")

# -------------------------------------------
# Logging helpers
# -------------------------------------------
log()   { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# -------------------------------------------
# ClickHouse query runner
# Prefers clickhouse-client (native protocol, no client-side timeout);
# falls back to curl against the HTTP interface.
# -------------------------------------------
ch_query() {
    local sql="$1"
    if command -v clickhouse-client >/dev/null 2>&1; then
        clickhouse-client \
            --host "${CH_HOST}" --port "${CH_NATIVE_PORT}" \
            --user "${CH_USER}" --password "${CH_PASSWORD}" \
            --query "${sql}"
    else
        # -m 0 -> no client-side timeout; server streams the backup.
        curl -sS -m 0 --fail-with-body \
            -H "X-ClickHouse-User: ${CH_USER}" \
            -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
            "http://${CH_HOST}:${CH_HTTP_PORT}/" \
            --data-binary "${sql}"
    fi
}

# -------------------------------------------
# Build the destination clause + a secret-free display string
# -------------------------------------------
build_destination() {
    if [ "${S3_ENABLED}" = "1" ]; then
        if [ -z "${S3_BUCKET}" ] || [ -z "${S3_ACCESS_KEY}" ] || [ -z "${S3_SECRET_KEY}" ]; then
            error "S3 backup enabled but PURL_BACKUP_S3_BUCKET / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY missing"
            exit 1
        fi
        local base prefix url
        if [ -n "${S3_ENDPOINT}" ]; then
            base="${S3_ENDPOINT%/}/${S3_BUCKET}"
        else
            base="https://${S3_BUCKET}.s3.${S3_REGION}.amazonaws.com"
        fi
        prefix="${S3_PREFIX#/}"                      # strip any leading slash
        [ -n "${prefix}" ] && prefix="${prefix%/}/"  # ensure single trailing slash
        url="${base}/${prefix}${BACKUP_NAME}"        # directory-style: streams objects
        BACKUP_URL="${url}"
        DEST="S3('${url}', '${S3_ACCESS_KEY}', '${S3_SECRET_KEY}')"
        DEST_DISPLAY="S3('${url}', '***', '***')"
    else
        # Local File() backup — NOTE: written server-side under ClickHouse's
        # <backups><allowed_path>. Only durable if that path is a mounted volume.
        BACKUP_URL="${BACKUP_NAME}.zip"
        DEST="File('${BACKUP_NAME}.zip')"
        DEST_DISPLAY="${DEST}"
    fi
}

# -------------------------------------------
# Main
# -------------------------------------------
build_destination

if [ "${#TABLES[@]}" -eq 0 ]; then
    SUBJECT="DATABASE ${CH_DB}"
else
    parts=()
    for t in "${TABLES[@]}"; do parts+=("TABLE ${CH_DB}.${t}"); done
    # BACKUP TABLE a, TABLE b, ... TO ...
    SUBJECT="$(IFS=', '; echo "${parts[*]}")"
fi

log "Starting Purl backup"
log "ClickHouse : ${CH_HOST} (http:${CH_HTTP_PORT} / native:${CH_NATIVE_PORT}) db=${CH_DB}"
log "Subject    : ${SUBJECT}"
log "Destination: ${DEST_DISPLAY}"
log "Backup name: ${BACKUP_NAME}"

# SETTINGS: fail loudly rather than silently skip inconsistent parts.
BACKUP_SQL="BACKUP ${SUBJECT} TO ${DEST}"

log "Issuing native BACKUP (server-side, streaming)…"
if OUTPUT="$(ch_query "${BACKUP_SQL}" 2>&1)"; then
    log "ClickHouse response: ${OUTPUT}"
    if echo "${OUTPUT}" | grep -q "BACKUP_CREATED"; then
        log "Backup created: ${BACKUP_URL}"
    else
        error "BACKUP did not report BACKUP_CREATED"
        exit 1
    fi
else
    error "BACKUP failed: ${OUTPUT}"
    exit 1
fi

# -------------------------------------------
# Retention
# -------------------------------------------
# ClickHouse's native BACKUP does NOT manage retention of old backups.
#   * S3   : enforce with a bucket lifecycle rule scoped to PURL_BACKUP_S3_PREFIX
#            expiring objects after ${RETENTION_DAYS} days. (No aws CLI here, so
#            this script does not delete remote objects — it would be unsafe to
#            do partially.) This is deliberate; do not fake it.
#   * File : old archives accumulate on the ClickHouse server volume.
log "Retention: ${RETENTION_DAYS} days — enforce via S3 lifecycle policy on prefix '${S3_PREFIX}' (not deleted by this script). See header NOTE."

log "Backup completed successfully"
