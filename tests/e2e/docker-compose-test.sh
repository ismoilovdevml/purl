#!/usr/bin/env bash
#
# Docker Compose smoke test: bring the shipped stack up and prove it actually
# works end to end.
#
# What this script used to do, and why the E2E job was "green" while broken:
#
#   1. It POSTed to /api/v1/logs, a route that has never existed. The 404 was
#      handled with `warn "Ingest returned HTTP $INGEST_CODE"` and the script
#      carried on to print "All Docker Compose E2E tests passed!".
#   2. It never substituted CHANGE_ME_GENERATE_SECURE_PASSWORD in
#      docker/clickhouse/users.xml (install.sh does that, and CI never runs
#      install.sh), so ClickHouse rejected the application login.
#   3. It only checked that the ingest call returned 200 — never that the log
#      could be read back.
#
# Every assertion below now calls fail(). A check that cannot fail is not a
# check.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GREEN}[E2E]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test-only credentials for a throwaway stack.
export PURL_IMAGE_TAG="${PURL_IMAGE_TAG:-compose-e2e}"
export PURL_API_KEYS="compose-e2e-key"
export PURL_ADMIN_PASSWORD="compose-E2E-Pass-1234"
export PURL_SESSION_SECRET="compose-e2e-session-secret-0000000000000000"
export PURL_CLICKHOUSE_USER="purl"
export PURL_CLICKHOUSE_PASSWORD="compose-E2E-CH-1234"
export PURL_AUTH_ENABLED=1

RUN_DIR="$(mktemp -d)"
CONFIG_DIR="$RUN_DIR/config"
USERS_XML="$RUN_DIR/users-e2e.xml"
OVERRIDE="$RUN_DIR/docker-compose.override.yml"
mkdir -p "$CONFIG_DIR"

COMPOSE_ARGS=(
    --project-name purl-compose-e2e
    -f "$PROJECT_ROOT/docker-compose.yml"
    -f "$OVERRIDE"
)

cleanup() {
    log "Stopping services..."
    docker compose "${COMPOSE_ARGS[@]}" logs --tail=100 purl 2>/dev/null || true
    docker compose "${COMPOSE_ARGS[@]}" down -v --remove-orphans 2>/dev/null || true
    rm -rf "$RUN_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# ClickHouse credentials.
#
# The shipped users.xml carries a placeholder password. Rather than sed-editing
# a tracked file (which leaves a dirty tree if the run is killed), mount an
# extra users.d entry: ClickHouse merges users.d/*.xml in filename order, so
# this overrides only the <password> nodes and the shipped profiles/ACLs still
# apply.
# ---------------------------------------------------------------------------
cat > "$USERS_XML" <<EOF
<?xml version="1.0"?>
<clickhouse>
    <users>
        <default><password>${PURL_CLICKHOUSE_PASSWORD}</password></default>
        <purl><password>${PURL_CLICKHOUSE_PASSWORD}</password></purl>
    </users>
</clickhouse>
EOF

cat > "$OVERRIDE" <<EOF
services:
  purl:
    container_name: purl-compose-e2e
    build:
      context: $PROJECT_ROOT
    image: ismoilovdev/purl:${PURL_IMAGE_TAG}
    volumes:
      - $CONFIG_DIR:/app/config
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/health"]
      interval: 3s
      timeout: 3s
      retries: 40
      start_period: 5s
  clickhouse:
    container_name: purl-clickhouse-compose-e2e
    environment:
      # The entrypoint probes the server as CLICKHOUSE_USER with
      # CLICKHOUSE_PASSWORD. Once the overlay above gives \`default\` a password,
      # omitting this makes first boot fail with AUTHENTICATION_FAILED.
      - CLICKHOUSE_PASSWORD=${PURL_CLICKHOUSE_PASSWORD}
    volumes:
      - $USERS_XML:/etc/clickhouse-server/users.d/users-e2e.xml:ro
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:8123/ping"]
      interval: 3s
      timeout: 3s
      retries: 40
      start_period: 15s
EOF

log "Starting Purl + ClickHouse via Docker Compose (building from the working tree)..."
docker compose "${COMPOSE_ARGS[@]}" up -d --build --wait \
    || fail "docker compose up failed"

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------
log "Waiting for health endpoint..."
HTTP_CODE=""
for _ in $(seq 1 30); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health 2>/dev/null) || true
    [[ "$HTTP_CODE" == "200" ]] && break
    sleep 2
done
[[ "$HTTP_CODE" == "200" ]] || fail "Service didn't become healthy in 60s (last HTTP: ${HTTP_CODE:-none})"
log "Health check passed."

# ---------------------------------------------------------------------------
# Ingest — POST /api/logs (NOT /api/v1/logs, which does not exist)
# ---------------------------------------------------------------------------
MARKER="compose-e2e-$(date +%s)-$RANDOM"
log "Ingesting a log (marker: $MARKER)..."
INGEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:3000/api/logs \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${PURL_API_KEYS}" \
    -d "[{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"level\":\"ERROR\",\"service\":\"compose-e2e\",\"message\":\"$MARKER\"}]")
[[ "$INGEST_CODE" == "200" ]] || fail "Ingest failed: HTTP $INGEST_CODE (expected 200)"
log "Ingest accepted (HTTP 200)."

# ---------------------------------------------------------------------------
# Read-back — the assertion that actually proves the pipeline works.
# A 200 from ingest only means the request was accepted.
# ---------------------------------------------------------------------------
log "Verifying the log is searchable..."
FOUND=0
BODY=""
for _ in $(seq 1 20); do
    BODY=$(curl -s --get http://localhost:3000/api/logs \
        --data-urlencode "q=$MARKER" -d limit=10 -d range=15m \
        -H "X-API-Key: ${PURL_API_KEYS}" 2>/dev/null) || true
    if grep -q -- "$MARKER" <<<"$BODY"; then
        FOUND=1
        break
    fi
    sleep 2
done
[[ "$FOUND" == "1" ]] || fail "Ingested log '$MARKER' was never searchable (last response: ${BODY:-none})"
log "Round-trip verified: ingest -> ClickHouse -> search."

# ---------------------------------------------------------------------------
# Auth must actually be enforced.
# ---------------------------------------------------------------------------
log "Verifying the ingest endpoint rejects a bad API key..."
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:3000/api/logs \
    -H "Content-Type: application/json" \
    -H "X-API-Key: definitely-not-the-key" \
    -d '[{"level":"INFO","message":"should be rejected"}]')
[[ "$UNAUTH_CODE" == "401" || "$UNAUTH_CODE" == "403" ]] \
    || fail "Ingest with an invalid API key returned HTTP $UNAUTH_CODE (expected 401/403)"
log "Unauthenticated ingest correctly rejected (HTTP $UNAUTH_CODE)."

# ---------------------------------------------------------------------------
# Containers must still be running at the end, not restarting.
# ---------------------------------------------------------------------------
log "Container status:"
docker compose "${COMPOSE_ARGS[@]}" ps

for svc in purl clickhouse; do
    state=$(docker compose "${COMPOSE_ARGS[@]}" ps --format '{{.State}}' "$svc" | head -1)
    [[ "$state" == "running" ]] || fail "Service '$svc' is in state '$state' (expected running)"
done

log "All Docker Compose E2E tests passed."
