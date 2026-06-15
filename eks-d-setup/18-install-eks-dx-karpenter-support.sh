#!/bin/bash
# 18-install-eks-dx-karpenter-support.sh
# Delegates to the canonical install script baked into the AMI at build time.
# Source: eks-d-xpress-control-plane release assets
#
# Prerequisites: cert-manager (11), Karpenter (15)
# Required env (via /opt/eks-d/cluster.env):
#   CLUSTER_NAME, TENANT_ID, AWS_REGION
set -eo pipefail

[ -f /opt/eks-d/cluster.env ] && source /opt/eks-d/cluster.env
[ -f /opt/eks-d/version.env ] && source /opt/eks-d/version.env

CANONICAL_SCRIPT="$(dirname "$0")/install-eks-dx-karpenter-support.sh"
if [ ! -f "$CANONICAL_SCRIPT" ]; then
  echo "Error: $CANONICAL_SCRIPT not found — was the AMI built correctly?"
  exit 1
fi

export CLUSTER_NAME TENANT_ID AWS_REGION EKS_DX_CONTROL_PLANE_VERSION
export CHART_DIR="/opt/eks-d-setup/charts"

exec bash "$CANONICAL_SCRIPT"
