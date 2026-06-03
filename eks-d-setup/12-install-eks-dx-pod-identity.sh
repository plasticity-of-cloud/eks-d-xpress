#!/bin/bash
# 12-install-eks-dx-pod-identity.sh
# Delegates to the canonical install script baked into the AMI at build time.
# Source: eks-d-xpress-control-plane release assets
#
# Prerequisites: cert-manager (11-install-cert-manager.sh)
# Required env (via /opt/eks-d/cluster.env):
#   EKS_DX_ENDPOINT, CLUSTER_NAME, AWS_REGION
set -eo pipefail

[ -f /opt/eks-d/cluster.env ]  && source /opt/eks-d/cluster.env
[ -f /opt/eks-d/version.env ]  && source /opt/eks-d/version.env

if [ -z "${EKS_DX_ENDPOINT:-}" ]; then
  echo "Skipping EKS-DX Pod Identity (EKS_DX_ENDPOINT not set)"
  exit 0
fi

CANONICAL_SCRIPT="/opt/eks-d/scripts/install-eks-dx-pod-identity.sh"
if [ ! -f "$CANONICAL_SCRIPT" ]; then
  echo "Error: $CANONICAL_SCRIPT not found — was the AMI built correctly?"
  exit 1
fi

export EKS_DX_ENDPOINT CLUSTER_NAME AWS_REGION EKS_DX_CONTROL_PLANE_VERSION
export CHART_DIR="/opt/eks-d/charts"

exec bash "$CANONICAL_SCRIPT"
