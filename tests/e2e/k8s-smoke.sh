#!/usr/bin/env bash
#
# Kubernetes smoke test on a throwaway Kind cluster.
#
# Two things made this script report success while the job was failing:
#
#   1. It did not disable the Vector DaemonSet. Vector's shipped config reads
#      journald, which does not exist in a Kind node, so the DaemonSet never
#      became ready — and `--wait` timed out or the pods crash-looped.
#   2. Ingest and metrics were asserted with `warn`, not `fail`, and it POSTed
#      to /api/v1/logs, a route that has never existed. So a 404 printed a
#      yellow line and the script ended with "All K8s E2E tests passed!".
#
# Every check below exits non-zero on failure.
set -euo pipefail

CLUSTER_NAME="purl-e2e"
NAMESPACE="purl-test"
IMAGE_TAG="e2e-test"
API_KEY="k8s-e2e-key"
CH_PASSWORD="k8s-E2E-CH-1234"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GREEN}[E2E]${NC} $1"; }
fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    # Diagnostics beat guesswork when this fails in CI.
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || true
    kubectl describe pods -n "$NAMESPACE" 2>/dev/null | tail -60 || true
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=purl --tail=100 2>/dev/null || true
    exit 1
}

PF_PID=""
cleanup() {
    log "Cleaning up..."
    [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

command -v kind    >/dev/null 2>&1 || fail "kind is not installed"
command -v helm    >/dev/null 2>&1 || fail "helm is not installed"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is not installed"

log "Creating Kind cluster..."
kind create cluster --name "$CLUSTER_NAME" --wait 60s || fail "kind create cluster failed"

log "Building Docker image..."
docker build -t "ismoilovdev/purl:${IMAGE_TAG}" "$PROJECT_ROOT" || fail "docker build failed"
kind load docker-image "ismoilovdev/purl:${IMAGE_TAG}" --name "$CLUSTER_NAME" \
    || fail "kind load docker-image failed"

log "Installing Purl via Helm..."
kubectl create namespace "$NAMESPACE"
helm install purl "$PROJECT_ROOT/chart" \
    --namespace "$NAMESPACE" \
    --set image.tag="${IMAGE_TAG}" \
    --set image.pullPolicy=Never \
    --set purl.apiKeys="${API_KEY}" \
    --set purl.authEnabled=false \
    --set clickhouse.password="${CH_PASSWORD}" \
    `# Vector tails journald, which a Kind node does not have. Leaving it on` \
    `# means the DaemonSet never goes Ready and --wait fails on an unrelated` \
    `# component. Log collection is covered by the compose test's ingest path.` \
    --set vector.enabled=false \
    --wait --timeout=300s \
    || fail "helm install failed"

log "Waiting for pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=purl \
    --namespace "$NAMESPACE" --timeout=180s || fail "purl pods never became ready"

log "Setting up port-forward..."
kubectl port-forward svc/purl 3333:3000 -n "$NAMESPACE" &
PF_PID=$!

# Wait for the tunnel instead of assuming 3 seconds is enough.
READY=0
for _ in $(seq 1 30); do
    if curl -sf -o /dev/null http://localhost:3333/api/health 2>/dev/null; then
        READY=1
        break
    fi
    sleep 2
done
[[ "$READY" == "1" ]] || fail "port-forward to svc/purl never became usable"

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------
log "Testing health endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3333/api/health)
[[ "$HTTP_CODE" == "200" ]] || fail "Health check failed: HTTP $HTTP_CODE"
log "Health check passed."

# ---------------------------------------------------------------------------
# Ingest — POST /api/logs (NOT /api/v1/logs)
# ---------------------------------------------------------------------------
MARKER="k8s-e2e-$(date +%s)-$RANDOM"
log "Testing log ingest (marker: $MARKER)..."
INGEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:3333/api/logs \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${API_KEY}" \
    -d "[{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"level\":\"INFO\",\"service\":\"k8s-e2e\",\"message\":\"$MARKER\"}]")
[[ "$INGEST_CODE" == "200" ]] || fail "Ingest failed: HTTP $INGEST_CODE (expected 200)"
log "Ingest accepted (HTTP 200)."

# ---------------------------------------------------------------------------
# Read-back
# ---------------------------------------------------------------------------
log "Verifying the log is searchable..."
FOUND=0
BODY=""
for _ in $(seq 1 20); do
    BODY=$(curl -s --get http://localhost:3333/api/logs \
        --data-urlencode "q=$MARKER" -d limit=10 -d range=15m \
        -H "X-API-Key: ${API_KEY}" 2>/dev/null) || true
    if echo "$BODY" | grep -q "$MARKER"; then
        FOUND=1
        break
    fi
    sleep 2
done
[[ "$FOUND" == "1" ]] || fail "Ingested log '$MARKER' was never searchable (last response: ${BODY:-none})"
log "Round-trip verified: ingest -> ClickHouse -> search."

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------
log "Testing metrics endpoint..."
METRICS=$(curl -sf http://localhost:3333/api/metrics 2>/dev/null) \
    || fail "GET /api/metrics did not return successfully"
echo "$METRICS" | grep -q "purl_" \
    || fail "Metrics response contains no purl_* series (got: $(echo "$METRICS" | head -c 200))"
log "Metrics endpoint OK."

# ---------------------------------------------------------------------------
# No pod may be crash-looping at the end of the run.
# ---------------------------------------------------------------------------
log "Pod status summary:"
kubectl get pods -n "$NAMESPACE" -o wide

RESTARTS=$(kubectl get pods -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' \
    | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -rn | head -1)
[[ -z "$RESTARTS" || "$RESTARTS" -eq 0 ]] \
    || fail "A container restarted ${RESTARTS} time(s) during the smoke test"

NOT_RUNNING=$(kubectl get pods -n "$NAMESPACE" \
    --field-selector=status.phase!=Running,status.phase!=Succeeded \
    -o name 2>/dev/null || true)
[[ -z "$NOT_RUNNING" ]] || fail "Pods not in a healthy phase: $NOT_RUNNING"

log "All K8s E2E tests passed."
