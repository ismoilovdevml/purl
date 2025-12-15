#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NAMESPACE="${PURL_NAMESPACE:-purl}"

echo -e "${YELLOW}Uninstalling Purl from namespace: ${NAMESPACE}${NC}"
echo ""

read -p "Delete all data (PVCs)? [y/N]: " DELETE_DATA

kubectl delete deployment purl -n "$NAMESPACE" --ignore-not-found
kubectl delete statefulset clickhouse -n "$NAMESPACE" --ignore-not-found
kubectl delete daemonset vector -n "$NAMESPACE" --ignore-not-found
kubectl delete service purl clickhouse -n "$NAMESPACE" --ignore-not-found
kubectl delete configmap purl-config vector-config -n "$NAMESPACE" --ignore-not-found
kubectl delete secret purl-secrets -n "$NAMESPACE" --ignore-not-found

if [[ "$DELETE_DATA" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}→${NC} Deleting PVCs..."
    kubectl delete pvc -l app=clickhouse -n "$NAMESPACE" --ignore-not-found
fi

kubectl delete namespace "$NAMESPACE" --ignore-not-found

echo ""
echo -e "${GREEN}✓ Purl uninstalled${NC}"
