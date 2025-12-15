#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="${PURL_NAMESPACE:-purl}"
REPO_URL="https://raw.githubusercontent.com/ismoilovdevml/purl/main/deploy/kubernetes"

echo -e "${BLUE}"
echo "  ____            _ "
echo " |  _ \ _   _ _ _| |"
echo " | |_) | | | | '_| |"
echo " |  __/| |_| | | | |"
echo " |_|    \__,_|_| |_|"
echo -e "${NC}"
echo "Kubernetes Installer"
echo ""

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    echo "Install kubectl: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi

# Check cluster connection
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    echo "Check your kubeconfig or cluster status"
    exit 1
fi

echo -e "${GREEN}✓${NC} Connected to cluster: $(kubectl config current-context)"
echo ""

# Determine if running locally or via curl
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd)"

fetch_manifest() {
    local file="$1"
    if [[ -f "$SCRIPT_DIR/$file" ]]; then
        cat "$SCRIPT_DIR/$file"
    else
        curl -fsSL "$REPO_URL/$file"
    fi
}

# Generate passwords
CLICKHOUSE_PASSWORD=$(openssl rand -base64 24)
API_KEY=$(openssl rand -base64 32)

echo -e "${YELLOW}→${NC} Creating namespace: ${NAMESPACE}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo -e "${YELLOW}→${NC} Creating secrets"
kubectl create secret generic purl-secrets \
    --namespace="$NAMESPACE" \
    --from-literal=PURL_CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD" \
    --from-literal=PURL_API_KEYS="$API_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${YELLOW}→${NC} Applying manifests"
fetch_manifest "configmap.yaml" | kubectl apply -f -
fetch_manifest "clickhouse.yaml" | kubectl apply -f -
fetch_manifest "purl.yaml" | kubectl apply -f -
fetch_manifest "vector-daemonset.yaml" | kubectl apply -f -

echo -e "${YELLOW}→${NC} Waiting for ClickHouse..."
kubectl wait --for=condition=ready pod -l app=clickhouse -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

echo -e "${YELLOW}→${NC} Waiting for Purl..."
kubectl wait --for=condition=ready pod -l app=purl -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BLUE}API Key:${NC} $API_KEY"
echo ""
echo -e "  ${BLUE}Access Dashboard:${NC}"
echo "    kubectl port-forward -n $NAMESPACE svc/purl 3000:80"
echo "    Open: http://localhost:3000"
echo ""
echo -e "  ${BLUE}Check Status:${NC}"
echo "    kubectl get pods -n $NAMESPACE"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
