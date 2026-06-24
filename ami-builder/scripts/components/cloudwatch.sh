#!/bin/bash
set -e
source /tmp/ami-build.env
CHARTS_DIR="/opt/eks-d-setup/charts"

echo "  Pulling CloudWatch Observability chart..."
helm repo add aws-observability \
  https://aws-observability.github.io/helm-charts 2>/dev/null || true
helm repo update aws-observability
helm pull aws-observability/amazon-cloudwatch-observability --destination /tmp
sudo mv /tmp/amazon-cloudwatch-observability-*.tgz "${CHARTS_DIR}/"

echo "  Pulling CloudWatch images (public.ecr.aws via cache)..."
CHART=$(ls "${CHARTS_DIR}"/amazon-cloudwatch-observability-*.tgz | head -1)
helm template amazon-cloudwatch-observability "$CHART" \
  --set clusterName=build --set region=us-east-1 2>/dev/null | \
  python3 "${EXTRACT_IMAGES_PY}" | \
  grep -Ev 'windows|nvidia|neuron|dcgm-exporter|kubekins-e2e' | sort -u | while read img; do
    sudo ctr -n k8s.io images pull \
      --user "${ECR_CTR_USER}" \
      "$(echo "$img" | sed "s|public.ecr.aws/|${PUBLIC_ECR_CACHE}/|")" || true
  done

echo "✓ cloudwatch ready"
