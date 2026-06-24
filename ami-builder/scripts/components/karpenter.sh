#!/bin/bash
set -e
source /tmp/ami-build.env
CHARTS_DIR="/opt/eks-d-setup/charts"

echo "  Pulling Karpenter chart (${KARPENTER_VERSION})..."
helm registry logout public.ecr.aws 2>/dev/null || true
helm pull oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" --destination /tmp
sudo mv /tmp/karpenter-*.tgz "${CHARTS_DIR}/"

echo "  Pulling Karpenter images (public.ecr.aws direct)..."
CHART=$(ls "${CHARTS_DIR}"/karpenter-*.tgz | head -1)
helm template karpenter "$CHART" 2>/dev/null | \
  python3 "${EXTRACT_IMAGES_PY}" | grep 'public\.ecr\.aws' | sort -u | while read img; do
    sudo ctr -n k8s.io images pull "$img" || true
  done

echo "✓ karpenter ready"
