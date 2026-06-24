#!/bin/bash
set -e
source /tmp/ami-build.env
CHARTS_DIR="/opt/eks-d-setup/charts"

echo "  Pulling cert-manager chart (${CERT_MANAGER_VERSION})..."
helm repo add jetstack https://charts.jetstack.io --force-update 2>/dev/null
helm pull jetstack/cert-manager --version "${CERT_MANAGER_VERSION}" --destination /tmp
sudo mv /tmp/cert-manager-*.tgz "${CHARTS_DIR}/"

echo "  Pulling cert-manager images (quay.io via ECR cache)..."
CHART=$(ls "${CHARTS_DIR}"/cert-manager-*.tgz | head -1)
helm template cert-manager "$CHART" --set crds.enabled=true 2>/dev/null | \
  python3 "${EXTRACT_IMAGES_PY}" | grep 'quay\.io' | sort -u | while read img; do
    sudo ctr -n k8s.io images pull \
      --user "${ECR_CTR_USER}" \
      "$(echo "$img" | sed "s|quay.io/|${QUAY_CACHE}/|")" || true
  done

echo "✓ cert-manager ready"
