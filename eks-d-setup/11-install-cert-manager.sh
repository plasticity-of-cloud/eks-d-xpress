#!/bin/bash
set -e

# Install cert-manager for TLS certificate lifecycle management.
# Required by: CloudWatch Observability webhooks, custom admission webhooks,
# and future EKS Pod Identity Agent integration.

CERT_MANAGER_VERSION="v1.17.1"

echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."

# Use pre-cached chart if available
CHART="/opt/eks-d/charts/cert-manager-${CERT_MANAGER_VERSION}.tgz"
if [ ! -f "$CHART" ]; then
  CHART="jetstack/cert-manager"
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm repo update jetstack
fi

helm upgrade --install cert-manager "$CHART" \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout=60s

# Verify cert-manager is ready
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=60s || {
  echo "Warning: cert-manager not ready within timeout"
}
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=60s || {
  echo "Warning: cert-manager-webhook not ready within timeout"
}

echo "✓ cert-manager installed"
kubectl get pods -n cert-manager
