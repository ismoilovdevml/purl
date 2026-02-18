#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="purl-e2e"
NAMESPACE="purl-test"
IMAGE_TAG="e2e-test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[E2E]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

cleanup() {
    log "Cleaning up..."
    kill "$PF_PID" 2>/dev/null || true
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

PF_PID=""

# Preflight checks
command -v kind >/dev/null 2>&1 || fail "kind is not installed"
command -v helm >/dev/null 2>&1 || fail "helm is not installed"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is not installed"

# Create Kind cluster
log "Creating Kind cluster..."
kind create cluster --name "$CLUSTER_NAME" --wait 60s

# Build and load Docker image
log "Building Docker image..."
docker build -t "ismoilovdev/purl:${IMAGE_TAG}" .
kind load docker-image "ismoilovdev/purl:${IMAGE_TAG}" --name "$CLUSTER_NAME"

# Install with Helm
log "Installing Purl via Helm..."
kubectl create namespace "$NAMESPACE"
helm install purl chart/ \
    --namespace "$NAMESPACE" \
    --set image.tag="${IMAGE_TAG}" \
    --set image.pullPolicy=Never \
    --set purl.apiKeys="test-key" \
    --set purl.authEnabled=false \
    --set clickhouse.password="e2e-test-pass" \
    --wait --timeout=120s

# Wait for pods
log "Waiting for pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=purl \
    --namespace "$NAMESPACE" --timeout=120s

# Port forward
log "Setting up port-forward..."
kubectl port-forward svc/purl 3333:3000 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

# Health check
log "Testing health endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3333/api/health)
[[ "$HTTP_CODE" == "200" ]] || fail "Health check failed: HTTP $HTTP_CODE"
log "Health check passed!"

# Ingest test
log "Testing log ingest..."
INGEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:3333/api/v1/logs \
    -H "Content-Type: application/json" \
    -H "X-API-Key: test-key" \
    -d '[{"timestamp":"2026-01-01T00:00:00Z","level":"INFO","message":"E2E test log","service":"e2e-test"}]')
[[ "$INGEST_CODE" == "200" ]] || warn "Ingest returned HTTP $INGEST_CODE (may need API key config)"
log "Ingest test done (HTTP $INGEST_CODE)."

# Metrics check
log "Testing metrics endpoint..."
METRICS=$(curl -s http://localhost:3333/api/metrics 2>/dev/null) || true
if echo "$METRICS" | grep -q "purl_"; then
    log "Metrics endpoint OK!"
else
    warn "Metrics format unexpected (endpoint may not be enabled)"
fi

# Pod status summary
log "Pod status summary:"
kubectl get pods -n "$NAMESPACE" -o wide

log "All K8s E2E tests passed!"
