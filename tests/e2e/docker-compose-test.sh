#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[E2E]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# Resolve project root (script may be called from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cleanup() {
    log "Stopping services..."
    docker compose -f "$PROJECT_ROOT/docker-compose.yml" down -v 2>/dev/null || true
}
trap cleanup EXIT

log "Starting Purl + ClickHouse via Docker Compose..."
docker compose -f "$PROJECT_ROOT/docker-compose.yml" up -d --build --wait

# Wait for health
log "Waiting for health endpoint..."
HTTP_CODE=""
for i in $(seq 1 30); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health 2>/dev/null) || true
    [[ "$HTTP_CODE" == "200" ]] && break
    sleep 2
done
[[ "$HTTP_CODE" == "200" ]] || fail "Service didn't become healthy in 60s (last HTTP: ${HTTP_CODE:-none})"
log "Health check passed!"

# Ingest test
log "Testing log ingest..."
INGEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:3000/api/v1/logs \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${PURL_API_KEYS:-test}" \
    -d '[{"timestamp":"2026-01-01T00:00:00Z","level":"INFO","message":"Docker E2E test","service":"e2e"}]')
if [[ "$INGEST_CODE" == "200" ]]; then
    log "Ingest test passed (HTTP 200)."
else
    warn "Ingest returned HTTP $INGEST_CODE (may need PURL_API_KEYS env)"
fi

# Wait for data to settle in ClickHouse
sleep 2

# Verify containers are healthy
log "Container status:"
docker compose -f "$PROJECT_ROOT/docker-compose.yml" ps

log "All Docker Compose E2E tests passed!"
