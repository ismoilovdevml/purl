#!/usr/bin/env bash
# Purl — ClickHouse Restore Script
# Restores a backup archive created by backup.sh into ClickHouse via HTTP API.
#
# Usage:
#   ./restore.sh /backups/purl_backup_20260218_120000.tar.gz
#
# Environment variables (with defaults):
#   CLICKHOUSE_HOST   — ClickHouse hostname (default: clickhouse)
#   CLICKHOUSE_PORT   — ClickHouse HTTP port (default: 8123)
#   CLICKHOUSE_DB     — Database name (default: purl)

set -euo pipefail

# -------------------------------------------
# Configuration
# -------------------------------------------
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-clickhouse}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_DB="${CLICKHOUSE_DB:-purl}"

# -------------------------------------------
# Logging helpers
# -------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# -------------------------------------------
# Validate arguments
# -------------------------------------------
if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup-archive.tar.gz>"
    echo ""
    echo "Example:"
    echo "  $0 /backups/purl_backup_20260218_120000.tar.gz"
    exit 1
fi

ARCHIVE_PATH="$1"

if [ ! -f "${ARCHIVE_PATH}" ]; then
    error "Backup archive not found: ${ARCHIVE_PATH}"
    exit 1
fi

# -------------------------------------------
# Extract archive
# -------------------------------------------
EXTRACT_DIR=$(mktemp -d)
trap 'rm -rf "${EXTRACT_DIR}"' EXIT

log "Starting Purl restore from: ${ARCHIVE_PATH}"
log "ClickHouse: ${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/${CLICKHOUSE_DB}"
log "Extracting archive to: ${EXTRACT_DIR}"

tar -xzf "${ARCHIVE_PATH}" -C "${EXTRACT_DIR}"

# Find the backup directory inside the extract (purl_backup_TIMESTAMP/)
BACKUP_DIR=$(find "${EXTRACT_DIR}" -mindepth 1 -maxdepth 1 -type d | head -1)

if [ -z "${BACKUP_DIR}" ]; then
    error "No backup directory found inside archive"
    exit 1
fi

log "Backup directory: ${BACKUP_DIR}"

# -------------------------------------------
# Restore each CSV file
# -------------------------------------------
RESTORED=0
FAILED=0

for csv_file in "${BACKUP_DIR}"/*.csv; do
    if [ ! -f "${csv_file}" ]; then
        log "No CSV files found in backup"
        break
    fi

    # Derive table name from filename (e.g., logs.csv -> logs)
    table=$(basename "${csv_file}" .csv)
    row_count=$(($(wc -l < "${csv_file}") - 1))

    log "Restoring table: ${CLICKHOUSE_DB}.${table} (${row_count} rows)"

    if curl -sf \
        --data-binary "@${csv_file}" \
        "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/?query=INSERT+INTO+${CLICKHOUSE_DB}.${table}+FORMAT+CSVWithNames"; then
        log "  -> ${table}: restored successfully"
        RESTORED=$((RESTORED + 1))
    else
        error "Failed to restore table: ${table}"
        FAILED=$((FAILED + 1))
    fi
done

# -------------------------------------------
# Summary
# -------------------------------------------
log "Restore summary: ${RESTORED} table(s) restored, ${FAILED} failed"

if [ "${FAILED}" -eq 0 ]; then
    log "Restore completed successfully from: ${ARCHIVE_PATH}"
else
    error "Restore completed with ${FAILED} error(s)"
    exit 1
fi
