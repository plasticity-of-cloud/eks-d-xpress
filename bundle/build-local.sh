#!/usr/bin/env bash
# Build the EKS-D-Xpress bundle image locally.
# Downloads release artifacts from GitHub using versions in bundle-versions.env.
#
# Usage:
#   ./bundle/build-local.sh [IMAGE_TAG]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
IMAGE_TAG="${1:-eks-d-xpress-bundle:local}"

source "${SCRIPT_DIR}/bundle-versions.env"

CP_VER="${CONTROL_PLANE_VERSION}"
INFRA_VER="${INFRA_VERSION}"
ARCH=$(uname -m); [ "${ARCH}" = "aarch64" ] && ARCH="arm64" || ARCH="amd64"

CP_BASE="https://github.com/plasticity-of-cloud/eks-d-xpress-control-plane/releases/download/v${CP_VER}"
INFRA_BASE="https://github.com/plasticity-of-cloud/eks-d-xpress-infra/releases/download/v${INFRA_VER}"

# ── Authenticate to ECR public gallery (required to pull base image) ─────────
echo "==> Authenticating to ECR public gallery..."
aws ecr-public get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin public.ecr.aws

# ── Download artifacts ───────────────────────────────────────────────────────
echo "==> Downloading control-plane v${CP_VER}..."
rm -rf "${BUILD_DIR}" && mkdir -p "${BUILD_DIR}/helm"

curl -fsSL "${CP_BASE}/eks-d-xpress-control-plane-${CP_VER}.tar.gz" \
  | tar xz -C "${BUILD_DIR}" --strip-components=1 --one-top-level=control-plane-cdk

echo "==> Downloading infra v${INFRA_VER}..."
curl -fsSL "${INFRA_BASE}/eks-d-xpress-infra-${INFRA_VER}.tar.gz" \
  | tar xz -C "${BUILD_DIR}" --strip-components=1 --one-top-level=infra-cdk

echo "==> Downloading eks-dx CLI (${ARCH})..."
curl -fsSL "${CP_BASE}/eks-dx-cli-${CP_VER}-linux-${ARCH}" \
  -o "${BUILD_DIR}/eks-dx-cli"
chmod +x "${BUILD_DIR}/eks-dx-cli"

echo "==> Downloading Helm charts..."
for chart in eks-d-xpress-auth-proxy eks-d-xpress-pod-identity-webhook eks-d-xpress-karpenter-support; do
  curl -fsSL "${CP_BASE}/${chart}-${CP_VER}.tar.gz" \
    -o "${BUILD_DIR}/helm/${chart}-${CP_VER}.tar.gz"
done

# AMI manifest from this repo's latest release (or empty stub for local dev)
if [ -f "${ROOT}/ami-manifest.json" ]; then
  cp "${ROOT}/ami-manifest.json" "${BUILD_DIR}/ami-manifest.json"
else
  echo '{}' > "${BUILD_DIR}/ami-manifest.json"
  echo "  Warning: no ami-manifest.json — using empty stub"
fi

cp "${SCRIPT_DIR}/Dockerfile" "${BUILD_DIR}/Dockerfile"
cp "${SCRIPT_DIR}/deploy.sh"  "${BUILD_DIR}/deploy.sh"

# ── Build ────────────────────────────────────────────────────────────────────
echo "==> Building ${IMAGE_TAG}..."
docker build -t "${IMAGE_TAG}" "${BUILD_DIR}"

echo ""
echo "✓ Built ${IMAGE_TAG}"
echo ""
echo "Run interactively (credentials file):"
echo "  docker run --rm -it -v ~/.aws:/root/.aws:ro -e AWS_REGION=us-east-1 ${IMAGE_TAG} bash"
echo ""
echo "Run interactively (env vars / EC2 / CloudShell):"
echo "  docker run --rm -it -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION=us-east-1 ${IMAGE_TAG} bash"
