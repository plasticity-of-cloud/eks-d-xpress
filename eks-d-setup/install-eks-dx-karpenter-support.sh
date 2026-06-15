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
GHCR_REGISTRY="ghcr.io/plasticity-of-cloud"

log "eks-dx-karpenter-support installation"
log "  Cluster:  ${CLUSTER_NAME}"
log "  Tenant:   ${TENANT_ID}"
log "  Region:   ${AWS_REGION}"
log "  Version:  ${EKS_DX_CONTROL_PLANE_VERSION}"

chart_ref() {
  local name="$1"
  local tgz
  tgz=$(ls "${CHART_DIR}/${name}"-*.tgz 2>/dev/null | head -1 || true)
  if [[ -n "$tgz" ]]; then
    echo "$tgz"
  else
    echo "oci://${GHCR_REGISTRY}/helm/${name} --version ${EKS_DX_CONTROL_PLANE_VERSION}"
  fi
}

# ── 1. Write eks-dx-config ConfigMap ─────────────────────────────────────────
# ClusterIdentityService reads cluster-name and tenant-id from this ConfigMap.
# apiServerEndpoint, ca.crt, and serviceSubnet are already in standard K8s ConfigMaps.
log "Writing eks-dx-config ConfigMap..."
kubectl create configmap eks-dx-config \
  -n kube-system \
  --from-literal=cluster-name="${CLUSTER_NAME}" \
  --from-literal=tenant-id="${TENANT_ID}" \
  --dry-run=client -o yaml | kubectl apply -f -
log "✓ eks-dx-config written"

# ── 2. Install Helm chart ─────────────────────────────────────────────────────
log "Installing eks-dx-karpenter-support..."
# shellcheck disable=SC2046
helm upgrade --install eks-dx-karpenter-support $(chart_ref eks-dx-karpenter-support) \
  --namespace kube-system \
  --wait --timeout=120s
log "✓ eks-dx-karpenter-support installed"

log "eks-dx-karpenter-support installation complete"
log "  EC2NodeClass amiFamily will be rewritten to Custom automatically"
log "  ValidationSucceeded condition will be patched by the controller"
log "  configure-nodepools.sh is no longer required"
