#!/bin/bash
set -e
source /tmp/ami-build.env
CHARTS_DIR="/opt/eks-d-setup/charts"

if [[ "${INSTALL_EKS_DX:-false}" != "true" ]]; then
  echo "  Skipping EKS-DX components (INSTALL_EKS_DX=false)"
  echo "✓ eks-dx skipped"
  exit 0
fi

echo "  Pulling EKS-DX Helm charts (v${EKS_DX_CONTROL_PLANE_VERSION})..."
for chart in eks-d-xpress-pod-identity-webhook eks-d-xpress-auth-proxy eks-d-xpress-karpenter-support; do
  helm pull "oci://${GHCR_EKS_D_XPRESS_REGISTRY}/helm/${chart}" \
    --version "${EKS_DX_CONTROL_PLANE_VERSION}" --destination /tmp || true
done
sudo mv /tmp/eks-d-xpress-*.tgz "${CHARTS_DIR}/" 2>/dev/null || true

echo "  Pulling EKS-DX container images..."
sudo ctr -n k8s.io images pull \
  "${GHCR_EKS_D_XPRESS_REGISTRY}/eks-d-xpress-auth-proxy:${EKS_DX_CONTROL_PLANE_VERSION}" || true
sudo ctr -n k8s.io images pull \
  "${GHCR_EKS_D_XPRESS_REGISTRY}/eks-d-xpress-pod-identity-webhook:${EKS_DX_CONTROL_PLANE_VERSION}" || true

echo "  Pulling eks-pod-identity-agent chart..."
mkdir -p /tmp/eks-pod-identity-agent
curl -sL https://github.com/aws/eks-pod-identity-agent/archive/refs/heads/main.tar.gz | \
  tar xz --strip-components=3 -C /tmp/eks-pod-identity-agent \
    eks-pod-identity-agent-main/charts/eks-pod-identity-agent || true
if [ -f /tmp/eks-pod-identity-agent/Chart.yaml ]; then
  helm package /tmp/eks-pod-identity-agent --destination /tmp || true
  sudo mv /tmp/eks-pod-identity-agent-*.tgz "${CHARTS_DIR}/" 2>/dev/null || true
fi
rm -rf /tmp/eks-pod-identity-agent

echo "  Pulling eks-pod-identity-agent image..."
sudo ctr -n k8s.io images pull \
  "602401143452.dkr.ecr.us-west-2.amazonaws.com/eks/eks-pod-identity-agent:latest" || true

echo "✓ eks-dx ready"
