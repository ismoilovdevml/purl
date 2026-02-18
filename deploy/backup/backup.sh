#!/usr/bin/env bash
# Purl — ClickHouse Backup Script
# Creates timestamped CSV backups of all Purl tables via ClickHouse HTTP API.
#
# Usage:
#   ./backup.sh
#
# Environment variables (with defaults):
#   CLICKHOUSE_HOST   — ClickHouse hostname (default: clickhouse)
#   CLICKHOUSE_PORT   — ClickHouse HTTP port (default: 8123)
#   CLICKHOUSE_DB     — Database name (default: purl)
#   BACKUP_DIR        — Backup storage path (default: /backups)
#   RETENTION_DAYS    — Days to keep old backups (default: 7)

set -euo pipefail

# -------------------------------------------
# Configuration
# -------------------------------------------
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-clickhouse}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_DB="${CLICKHOUSE_DB:-purl}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="purl_backup_${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Tables to back up
TABLES=(
    logs
    log_patterns
    alert_rules
    alert_history
    settings
)

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
# Main
# -------------------------------------------
log "Starting Purl backup"
log "ClickHouse: ${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/${CLICKHOUSE_DB}"
log "Backup directory: ${BACKUP_PATH}"
log "Retention: ${RETENTION_DAYS} days"

# Create backup directory
mkdir -p "${BACKUP_PATH}"

# Export each table to CSV
FAILED=0
for table in "${TABLES[@]}"; do
    log "Backing up table: ${CLICKHOUSE_DB}.${table}"

    output_file="${BACKUP_PATH}/${table}.csv"

    if curl -sf \
        "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/?query=SELECT+*+FROM+${CLICKHOUSE_DB}.${table}+FORMAT+CSVWithNames" \
        -o "${output_file}"; then
        row_count=$(wc -l < "${output_file}")
        log "  -> ${table}: $((row_count - 1)) rows exported"
    else
        error "Failed to backup table: ${table}"
        FAILED=$((FAILED + 1))
    fi
done

if [ "${FAILED}" -gt 0 ]; then
    error "${FAILED} table(s) failed to backup"
fi

# Compress backup
log "Compressing backup to ${BACKUP_PATH}.tar.gz"
tar -czf "${BACKUP_PATH}.tar.gz" -C "${BACKUP_DIR}" "${BACKUP_NAME}"

# Remove uncompressed directory
rm -rf "${BACKUP_PATH}"

# Calculate backup size
BACKUP_SIZE=$(du -h "${BACKUP_PATH}.tar.gz" | cut -f1)
log "Backup archive: ${BACKUP_PATH}.tar.gz (${BACKUP_SIZE})"

# -------------------------------------------
# Cleanup old backups
# -------------------------------------------
log "Cleaning up backups older than ${RETENTION_DAYS} days"
DELETED=$(find "${BACKUP_DIR}" -name "purl_backup_*.tar.gz" -type f -mtime +"${RETENTION_DAYS}" -print -delete | wc -l)
log "Deleted ${DELETED} old backup(s)"

# -------------------------------------------
# Summary
# -------------------------------------------
if [ "${FAILED}" -eq 0 ]; then
    log "Backup completed successfully: ${BACKUP_PATH}.tar.gz"
else
    error "Backup completed with ${FAILED} error(s)"
    exit 1
fi
