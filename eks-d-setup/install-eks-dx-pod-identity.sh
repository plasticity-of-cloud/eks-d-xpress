#!/usr/bin/env bash
# install-eks-dx-pod-identity.sh
#
# Installs EKS Pod Identity on any Kubernetes distribution (k3s, EKS-D, microk8s, etc.)
# by registering the cluster with the eks-dx control plane and deploying three components:
#   1. eks-dx-auth-proxy      — in-cluster TokenReview + credential forwarding
#   2. eks-dx-pod-identity-webhook — mutating webhook (env + projected token injection)
#   3. eks-pod-identity-agent — AWS DaemonSet (intercepts 169.254.170.23)
#
# Required environment variables:
#   CLUSTER_NAME                 — unique cluster identifier
#   AWS_REGION                   — AWS region
#   EKS_DX_CONTROL_PLANE_VERSION — eks-dx-control-plane release version (sourced from /opt/eks-d/version.env)
#
# Optional environment variables:
#   EKS_DX_ENDPOINT              — API Gateway URL override (default: resolved from SSM /eks-d-xpress/control-plane/api/endpoint)
#   KUBECONFIG                   — path to kubeconfig (default: standard lookup)
#   CHART_DIR                    — directory containing pre-downloaded chart tarballs (AMI bake path)
#                                  falls back to GHCR OCI pull if not set or charts not found
#
# Usage:
#   curl -sL https://github.com/plasticity-of-cloud/eks-d-xpress-control-plane/releases/download/vVERSION/install-eks-dx-pod-identity.sh \
#     | CLUSTER_NAME=my-cluster AWS_REGION=us-east-1 bash
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Validate required inputs ───────────────────────────────────────────────────
[[ -z "${CLUSTER_NAME:-}"    ]] && err "CLUSTER_NAME is required"
[[ -z "${AWS_REGION:-}"      ]] && err "AWS_REGION is required"

# ── Resolve EKS_DX_ENDPOINT (env → SSM → error) ───────────────────────────────
if [[ -z "${EKS_DX_ENDPOINT:-}" ]]; then
  EKS_DX_ENDPOINT=$(aws ssm get-parameter \
    --name /eks-d-xpress/control-plane/api/endpoint \
    --region "${AWS_REGION}" \
    --query Parameter.Value --output text 2>/dev/null || true)
fi
[[ -z "${EKS_DX_ENDPOINT:-}" ]] && err "EKS_DX_ENDPOINT could not be resolved — set env var or ensure SSM param /eks-d-xpress/control-plane/api/endpoint exists"

[[ -z "${EKS_DX_CONTROL_PLANE_VERSION:-}" ]] && err "EKS_DX_CONTROL_PLANE_VERSION is required — set it explicitly or ensure /opt/eks-d/version.env is present"

CHART_DIR="${CHART_DIR:-/opt/eks-d-setup/charts}"
GHCR_REGISTRY="ghcr.io/plasticity-of-cloud"

log "EKS-DX Pod Identity installation"
log "  Cluster:  ${CLUSTER_NAME}"
log "  Region:   ${AWS_REGION}"
log "  Endpoint: ${EKS_DX_ENDPOINT}"
log "  Version:  ${EKS_DX_CONTROL_PLANE_VERSION}"

# ── Helper: resolve chart (local cache first, GHCR OCI fallback) ──────────────
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

# ── 1. Register cluster ────────────────────────────────────────────────────────
log "Registering cluster with eks-dx control plane..."

ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])" 2>/dev/null || true)
[[ -z "$ISSUER" ]] && ISSUER="${EKS_DX_ENDPOINT}/clusters/${CLUSTER_NAME}"

kubectl get --raw /openid/v1/jwks > /tmp/eks-dx-jwks.json

eks-dx create cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --issuer "${ISSUER}" \
  --jwks-file /tmp/eks-dx-jwks.json || warn "Cluster registration returned non-zero (may already be registered)"

rm -f /tmp/eks-dx-jwks.json
log "✓ Cluster registered"

# ── 2. eks-dx-auth-proxy ──────────────────────────────────────────────────────
log "Installing eks-dx-auth-proxy..."
# shellcheck disable=SC2046
helm upgrade --install eks-dx-auth-proxy $(chart_ref eks-dx-auth-proxy) \
  --namespace kube-system \
  --set app.envs.EKS_DX_ENDPOINT="${EKS_DX_ENDPOINT}" \
  --set app.envs.AWS_REGION="${AWS_REGION}" \
  --wait --timeout=120s
log "✓ eks-dx-auth-proxy installed"

# ── 3. eks-dx-pod-identity-webhook ───────────────────────────────────────────
log "Installing eks-dx-pod-identity-webhook..."
# shellcheck disable=SC2046
helm upgrade --install eks-dx-pod-identity-webhook $(chart_ref eks-dx-pod-identity-webhook) \
  --namespace kube-system \
  --set app.envs.EKS_DX_ENDPOINT="${EKS_DX_ENDPOINT}" \
  --set app.envs.EKS_CLUSTER_NAME="${CLUSTER_NAME}" \
  --set app.envs.AWS_REGION="${AWS_REGION}" \
  --wait --timeout=120s
log "✓ eks-dx-pod-identity-webhook installed"

# ── 4. eks-pod-identity-agent ─────────────────────────────────────────────────
# The agent image is in AWS ECR us-west-2 — create a pull secret.
log "Creating ECR pull secret for eks-pod-identity-agent..."
kubectl create secret docker-registry ecr-pod-identity-agent \
  --namespace kube-system \
  --docker-server=602401143452.dkr.ecr.us-west-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region us-west-2)" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Installing eks-pod-identity-agent..."
AGENT_CHART=$(ls "${CHART_DIR}/eks-pod-identity-agent"-*.tgz 2>/dev/null | head -1 || true)
if [[ -z "$AGENT_CHART" ]]; then
  warn "eks-pod-identity-agent chart not in CHART_DIR — cloning from GitHub..."
  git clone --depth=1 https://github.com/aws/eks-pod-identity-agent.git /tmp/eks-pod-identity-agent-src
  AGENT_CHART="/tmp/eks-pod-identity-agent-src/charts/eks-pod-identity-agent"
fi

helm upgrade --install eks-pod-identity-agent "$AGENT_CHART" \
  --namespace kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set env.AWS_REGION="${AWS_REGION}" \
  --set "agent.additionalArgs.--endpoint=http://eks-dx-auth-proxy.kube-system.svc.cluster.local:8080" \
  --set "affinity=" \
  --set "imagePullSecrets[0].name=ecr-pod-identity-agent" \
  --wait --timeout=120s
log "✓ eks-pod-identity-agent installed"

log "EKS-DX Pod Identity installation complete"
log "  Test: kubectl run aws-test --image=amazon/aws-cli:latest --rm -it \\"
log "    --overrides='{\"spec\":{\"serviceAccountName\":\"<your-sa\"}}' -- sts get-caller-identity"
