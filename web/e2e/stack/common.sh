#!/usr/bin/env bash
# Shared helpers for the ephemeral Playwright stack (up.sh / down.sh).
# Not executable on its own; source it.

E2E_STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_REPO_ROOT="$(cd "$E2E_STACK_DIR/../../.." && pwd)"

log()  { echo "[e2e-stack] $*" >&2; }
fail() { echo "[e2e-stack] FAIL: $*" >&2; exit 1; }

# Compose project name — isolates the e2e stack from a developer's `make up`.
export PURL_E2E_PROJECT="purl-e2e"

# Runtime scratch lives OUTSIDE the repo on purpose: a killed run must never
# leave an untracked directory behind for someone to accidentally commit.
export PURL_E2E_RUN_DIR="${TMPDIR:-/tmp}/purl-e2e-stack"
export PURL_E2E_CONFIG_DIR="$PURL_E2E_RUN_DIR/config"
export PURL_E2E_USERS_XML="$PURL_E2E_RUN_DIR/users-e2e.xml"

e2e_load_env() {
    local env_file="$E2E_STACK_DIR/e2e.env"
    [[ -f "$env_file" ]] || fail "missing $env_file"
    # `set -a` exports everything the file defines so docker compose and this
    # script agree on one set of values.
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
    mkdir -p "$PURL_E2E_RUN_DIR"
}

e2e_compose() {
    docker compose \
        --project-name "$PURL_E2E_PROJECT" \
        --env-file "$E2E_STACK_DIR/e2e.env" \
        -f "$E2E_REPO_ROOT/docker-compose.yml" \
        -f "$E2E_STACK_DIR/docker-compose.e2e.yml" \
        "$@"
}
