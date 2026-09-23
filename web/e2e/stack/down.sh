#!/usr/bin/env bash
# Tear the ephemeral Purl stack down, volumes included.
#
# `-v` is not optional: the ClickHouse volume holds the logs a previous run
# ingested, and the config volume holds the settings and users it wrote. Leaving
# either behind makes the next run's assertions depend on run order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

e2e_load_env

if [[ "${PURL_E2E_KEEP_STACK:-0}" == "1" ]]; then
    log "PURL_E2E_KEEP_STACK=1 — leaving the stack running for debugging."
    log "Tear down later with: web/e2e/stack/down.sh"
    exit 0
fi

log "Stopping e2e stack..."
e2e_compose down -v --remove-orphans
rm -rf "$PURL_E2E_RUN_DIR"
log "Done."
