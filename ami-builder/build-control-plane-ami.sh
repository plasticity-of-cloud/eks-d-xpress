#!/usr/bin/env bash
# build.sh — Build EKS-D AMIs using Packer.
#
# Usage (interactive):
#   ./ami-builder/build.sh
#
# Usage (non-interactive, CI):
#   AWS_REGION=us-east-1 KUBERNETES_VERSION=1.35 AMI_VERSION=1.0.0 ARCH=arm64 \
#     ./ami-builder/build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EKS_D_XPRESS_DIR="$(dirname "${SCRIPT_DIR}")"
AMI_VERSION="${AMI_VERSION:-$(date +%Y%m%d-%H%M)}"

# ── Ensure packer is available ────────────────────────────────────────────────
ensure_packer() {
  command -v packer &>/dev/null && return
  echo "==> packer not found, installing..."
  local version; version=$(grep '^packer ' "${EKS_D_XPRESS_DIR}/.tool-versions" | awk '{print $2}')
  local arch; arch=$(uname -m); [ "$arch" = "aarch64" ] && arch="arm64" || arch="amd64"
  local os; os=$(uname -s | tr '[:upper:]' '[:lower:]')
  curl -fsSL "https://releases.hashicorp.com/packer/${version}/packer_${version}_${os}_${arch}.zip" \
    -o /tmp/packer.zip
  unzip -o /tmp/packer.zip -d /tmp && sudo mv /tmp/packer /usr/local/bin/packer && rm /tmp/packer.zip
  echo "    ✓ packer ${version} installed"
}

prompt() {
  local var="$1" msg="$2" default="$3"
  local current="${!var:-}"
  if [ -n "$current" ]; then echo "    ${msg} [${current}]: using env value"; return; fi
  read -rp "  ${msg} [${default}]: " input
  printf -v "$var" '%s' "${input:-$default}"
}

ensure_packer

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   EKS-DX Distribution — Build AMI           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

AWS_REGION="${AWS_REGION:-}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"
prompt AWS_REGION         "AWS region"          "us-east-1"
prompt KUBERNETES_VERSION "Kubernetes version"  "1.35"

ARCH="${ARCH:-both}"
case "${ARCH}" in
  arm64)   ONLY="-only=amazon-ebs.arm64" ;;
  x86_64)  ONLY="-only=amazon-ebs.x86_64" ;;
  both)    ONLY="" ;;
  *) echo "ERROR: ARCH must be arm64, x86_64, or both" >&2; exit 1 ;;
esac

# ── Stage ecr-credential-provider binaries ───────────────────────────────────
echo "" && echo "==> Staging ecr-credential-provider binaries..."
mkdir -p "${SCRIPT_DIR}/files"

case "${ARCH}" in
  arm64)  GOARCHES="arm64" ;;
  x86_64) GOARCHES="amd64" ;;
  both)   GOARCHES="amd64 arm64" ;;
esac

for GOARCH in ${GOARCHES}; do
  ARCH_DIR=$( [ "${GOARCH}" = "amd64" ] && echo "x86_64" || echo "arm64" )
  SRC="${EKS_D_XPRESS_DIR}/eks-d-setup/${ARCH_DIR}/ecr-credential-provider-${KUBERNETES_VERSION}"
  [ -f "${SRC}" ] || SRC="${EKS_D_XPRESS_DIR}/eks-d-setup/${ARCH_DIR}/ecr-credential-provider"
  if [ ! -f "${SRC}" ]; then
    echo "ERROR: ecr-credential-provider not found for ${GOARCH} (k8s ${KUBERNETES_VERSION})." >&2
    echo "       Push a tag to trigger the release workflow first." >&2
    exit 1
  fi
  cp "${SRC}" "${SCRIPT_DIR}/files/ecr-credential-provider-${GOARCH}"
  chmod +x "${SCRIPT_DIR}/files/ecr-credential-provider-${GOARCH}"
  echo "    ✓ ecr-credential-provider-${GOARCH} ($(basename "${SRC}"))"
done

# ── Run packer ────────────────────────────────────────────────────────────────
echo "" && echo "==> Building ${ARCH} AMI (~20-30 min)..."

LOG_FILE="${EKS_D_XPRESS_DIR}/packer-build-${AMI_VERSION}.log"
export PACKER_LOG=1
export PACKER_LOG_PATH="${LOG_FILE}"
echo "    Log: ${LOG_FILE}"

packer init "${SCRIPT_DIR}/eks-dx.pkr.hcl"
packer build \
  ${ONLY} \
  -var "aws_region=${AWS_REGION}" \
  -var "kubernetes_version=${KUBERNETES_VERSION}" \
  -var "ami_version=${AMI_VERSION}" \
  "${SCRIPT_DIR}/eks-dx.pkr.hcl"

# ── Clean up stale Packer security groups ────────────────────────────────────
echo "==> Cleaning up stale Packer security groups..."
aws ec2 describe-security-groups --region "${AWS_REGION}" \
  --filters "Name=group-name,Values=packer_*" \
  --query 'SecurityGroups[].GroupId' --output text \
| tr '\t' '\n' | while read -r sg; do
  [ -z "$sg" ] && continue
  echo "    Deleting stale SG: $sg"
  aws ec2 delete-security-group --group-id "$sg" --region "${AWS_REGION}" 2>/dev/null || true
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   AMI build complete                         ║"
echo "╚══════════════════════════════════════════════╝"
echo "  AMI IDs stored at SSM:"
echo "    /eks-d-xpress/infra/ami/${KUBERNETES_VERSION}/x86_64"
echo "    /eks-d-xpress/infra/ami/${KUBERNETES_VERSION}/arm64"
