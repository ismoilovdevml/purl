#!/usr/bin/env bash
#
# Bring up the ephemeral Purl stack for Playwright and then stay in the
# foreground streaming the app log.
#
# Playwright's `webServer` kills this process when the run finishes; staying in
# the foreground is what keeps the stack alive for the duration of the run and,
# just as importantly, puts the backend log in the Playwright output when a
# spec fails. A script that exits as soon as the stack is up makes Playwright
# report "process exited early" and hides every server-side error.
#
# Teardown is web/e2e/stack/down.sh, wired to Playwright globalTeardown.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# web/e2e/stack -> web/e2e -> web -> repo root
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

e2e_load_env

log "Project root:  $PROJECT_ROOT"
log "Runtime dir:   $PURL_E2E_RUN_DIR"
log "Image:         ismoilovdev/purl:${PURL_IMAGE_TAG}"

# Fresh config dir => fresh settings and a freshly bootstrapped admin user, so
# no spec depends on state a previous run left behind.
rm -rf "$PURL_E2E_CONFIG_DIR"
mkdir -p "$PURL_E2E_CONFIG_DIR"

# Render the ClickHouse overlay BEFORE any compose command touches it.
# Docker Desktop silently creates a missing bind-mount source as a *directory*,
# so a compose call that runs while this path does not exist leaves behind a
# directory named users-e2e.xml and every later run dies on "Is a directory".
rm -rf "$PURL_E2E_USERS_XML"
log "Rendering ClickHouse password overlay..."
sed "s|__CH_PASSWORD__|${PURL_CLICKHOUSE_PASSWORD}|g" \
    "$SCRIPT_DIR/users-e2e.xml" > "$PURL_E2E_USERS_XML"

# A leftover stack from a killed run would serve stale code and stale config,
# so always start from a clean slate.
log "Removing any previous e2e stack..."
e2e_compose down -v --remove-orphans >/dev/null 2>&1 || true

if [[ "${PURL_E2E_BUILD:-auto}" == "always" ]] || ! docker image inspect "ismoilovdev/purl:${PURL_IMAGE_TAG}" >/dev/null 2>&1; then
    log "Building ismoilovdev/purl:${PURL_IMAGE_TAG} from the working tree..."
    docker build -t "ismoilovdev/purl:${PURL_IMAGE_TAG}" "$PROJECT_ROOT"
else
    log "Reusing existing image (set PURL_E2E_BUILD=always to force a rebuild)."
fi

log "Starting stack..."
e2e_compose up -d --wait

log "Stack is up on http://localhost:${PURL_PORT}"
log "Streaming purl logs (Ctrl-C / Playwright teardown stops this)..."
exec docker compose \
    --project-name "$PURL_E2E_PROJECT" \
    -f "$PROJECT_ROOT/docker-compose.yml" \
    -f "$SCRIPT_DIR/docker-compose.e2e.yml" \
    logs -f purl
