#!/usr/bin/env bash
# install-eks-dx-karpenter-support.sh
#
# Installs eks-dx-karpenter-support — EC2NodeClass mutating webhook and
# ValidationSucceeded controller for Karpenter on non-EKS clusters.
#
# Also writes the eks-dx-config ConfigMap consumed by ClusterIdentityService
# at webhook runtime. This is the in-cluster identity contract that replaces
# the cluster-discovery portion of configure-nodepools.sh (deprecated).
#
# Required environment variables:
#   CLUSTER_NAME                 — unique cluster identifier
#   TENANT_ID                    — tenant identifier
#   AWS_REGION                   — AWS region
#   EKS_DX_CONTROL_PLANE_VERSION — release version (from /opt/eks-d/version.env)
#
# Optional:
#   CHART_DIR  — directory containing pre-downloaded chart tarballs (AMI bake path)
#                falls back to GHCR OCI pull if not set or chart not found
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ -z "${CLUSTER_NAME:-}"    ]] && err "CLUSTER_NAME is required"
[[ -z "${TENANT_ID:-}"       ]] && err "TENANT_ID is required"
[[ -z "${AWS_REGION:-}"      ]] && err "AWS_REGION is required"
[[ -z "${EKS_DX_CONTROL_PLANE_VERSION:-}" ]] && err "EKS_DX_CONTROL_PLANE_VERSION is required"

CHART_DIR="${CHART_DIR:-/opt/eks-d-setup/charts}"

# shellcheck source=../ami-builder/scripts/component-versions.env
# shellcheck disable=SC1091
[[ -f /opt/eks-d/component-versions.env ]] && source /opt/eks-d/component-versions.env
GHCR_EKS_D_XPRESS_REGISTRY="${GHCR_EKS_D_XPRESS_REGISTRY:-ghcr.io/plasticity-of-cloud}"

log "eks-dx-karpenter-support installation"
log "  Cluster:  ${CLUSTER_NAME}"
log "  Tenant:   ${TENANT_ID}"
log "  Region:   ${AWS_REGION}"
log "  Version:  ${EKS_DX_CONTROL_PLANE_VERSION}"

chart_ref() {
  local name="$1"
  local tgz
  tgz=$(ls "${CHART_DIR}/${name}"-*.tgz "${CHART_DIR}/${name}"-*.tar.gz 2>/dev/null | head -1 || true)
  if [[ -n "$tgz" ]]; then
    echo "$tgz"
  else
    echo "oci://${GHCR_EKS_D_XPRESS_REGISTRY}/helm/${name} --version ${EKS_DX_CONTROL_PLANE_VERSION}"
  fi
}

# ── 1. Resolve NAT gateway flag ───────────────────────────────────────────────
NAT_ENABLED=$(aws ssm get-parameter \
  --name "/eks-d-xpress/infra/network/nat-gateway-enabled" \
  --region "${AWS_REGION}" \
  --query Parameter.Value --output text 2>/dev/null || echo "false")

[[ -z "${PUBLIC_SUBNET_ID:-}"   ]] && warn "PUBLIC_SUBNET_ID not set in cluster.env"
[[ -z "${PRIVATE_SUBNET_ID:-}"  ]] && warn "PRIVATE_SUBNET_ID not set in cluster.env"
[[ -z "${SECURITY_GROUP_ID:-}"  ]] && warn "SECURITY_GROUP_ID not set in cluster.env"

# ── 2. Install Helm chart (eks-dx-config ConfigMap included in chart) ─────────
log "Installing eks-dx-karpenter-support..."
# shellcheck disable=SC2046
helm upgrade --install eks-dx-karpenter-support $(chart_ref eks-dx-karpenter-support) \
  --namespace kube-system \
  --set clusterIdentity.clusterName="${CLUSTER_NAME}" \
  --set clusterIdentity.tenantId="${TENANT_ID}" \
  --set clusterIdentity.natGatewayEnabled="${NAT_ENABLED}" \
  --set clusterIdentity.publicSubnetId="${PUBLIC_SUBNET_ID:-}" \
  --set clusterIdentity.privateSubnetId="${PRIVATE_SUBNET_ID:-}" \
  --set clusterIdentity.securityGroupId="${SECURITY_GROUP_ID:-}" \
  --wait --timeout=120s
log "✓ eks-dx-karpenter-support installed (eks-dx-config ConfigMap included)"

log "eks-dx-karpenter-support installation complete"
log "  EC2NodeClass amiFamily will be rewritten to Custom automatically"
log "  ValidationSucceeded condition will be patched by the controller"
log "  configure-nodepools.sh is no longer required"
