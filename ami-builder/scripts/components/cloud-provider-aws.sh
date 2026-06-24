#!/bin/bash
set -e
source /tmp/ami-build.env
CHARTS_DIR="/opt/eks-d-setup/charts"

echo "  Pulling cloud-provider-aws chart..."
helm repo add aws-cloud-controller-manager \
  https://kubernetes.github.io/cloud-provider-aws
helm repo update aws-cloud-controller-manager
helm pull aws-cloud-controller-manager/aws-cloud-controller-manager --destination /tmp
sudo mv /tmp/aws-cloud-controller-manager-*.tgz "${CHARTS_DIR}/"

echo "  Pulling cloud-provider-aws images (registry.k8s.io via cache)..."
CHART=$(ls "${CHARTS_DIR}"/aws-cloud-controller-manager-*.tgz | head -1)
helm template aws-cloud-controller-manager "$CHART" 2>/dev/null | \
  python3 "${EXTRACT_IMAGES_PY}" | sort -u | while read img; do
    sudo ctr -n k8s.io images pull \
      --user "${ECR_CTR_USER}" \
      "$(echo "$img" | sed \
          -e "s|public.ecr.aws/|${PUBLIC_ECR_CACHE}/|" \
          -e "s|registry.k8s.io/|${K8S_REGISTRY_CACHE}/|")" || true
  done

echo "✓ cloud-provider-aws ready"
