#!/bin/bash
set -e
source /tmp/ami-build.env
CHARTS_DIR="/opt/eks-d-setup/charts"

echo "  Pulling EBS CSI chart..."
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update aws-ebs-csi-driver
helm pull aws-ebs-csi-driver/aws-ebs-csi-driver --destination /tmp
sudo mv /tmp/aws-ebs-csi-driver-*.tgz "${CHARTS_DIR}/"

echo "  Pulling EBS CSI images (public.ecr.aws via cache)..."
CHART=$(ls "${CHARTS_DIR}"/aws-ebs-csi-driver-*.tgz | head -1)
helm template aws-ebs-csi-driver "$CHART" 2>/dev/null | \
  python3 "${EXTRACT_IMAGES_PY}" | \
  grep -Ev 'windows|nvidia|neuron|dcgm-exporter|kubekins-e2e|e2e-test' | sort -u | while read img; do
    sudo ctr -n k8s.io images pull \
      --user "${ECR_CTR_USER}" \
      "$(echo "$img" | sed "s|public.ecr.aws/|${PUBLIC_ECR_CACHE}/|")" || true
  done

echo "✓ ebs-csi ready"
