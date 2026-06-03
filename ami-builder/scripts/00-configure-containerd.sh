#!/bin/bash
set -e

# Source version info; fall back to current defaults if not present (fresh install path)
if [ -f /opt/eks-d/version.env ]; then
  source /opt/eks-d/version.env
else
  echo "Warning: /opt/eks-d/version.env not found, using defaults"
  EKS_VERSION="1.35"
  EKSD_VERSION="1.35.8"
fi

EKSD_MANIFEST_VERSION="${EKS_VERSION//./-}"
EKSD_RELEASE="${EKSD_VERSION##*.}"

echo "Configuring containerd for EKS-D ${EKS_VERSION} (release ${EKSD_RELEASE})..."

# Reuse pre-downloaded manifest if available, otherwise download
MANIFEST_FILE="/opt/eks-d/manifests/eks-d-release.yaml"
if [ ! -f "$MANIFEST_FILE" ]; then
  MANIFEST_FILE="/tmp/eks-d-release.yaml"
  if [ ! -f "$MANIFEST_FILE" ]; then
    curl -sL "https://distro.eks.amazonaws.com/kubernetes-${EKSD_MANIFEST_VERSION}/kubernetes-${EKSD_MANIFEST_VERSION}-eks-${EKSD_RELEASE}.yaml" \
      -o "$MANIFEST_FILE"
  fi
fi

PAUSE_IMAGE=$(grep "kubernetes/pause" "$MANIFEST_FILE" | grep "uri:" | head -1 | awk '{print $2}')
if [ -z "$PAUSE_IMAGE" ]; then
  echo "ERROR: Could not extract pause image from release manifest"
  exit 1
fi
echo "  pause image: ${PAUSE_IMAGE}"

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i "s|sandbox_image = .*|sandbox_image = \"${PAUSE_IMAGE}\"|" /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl is-active containerd

echo "✓ containerd configured (pause: ${PAUSE_IMAGE}, SystemdCgroup: true)"
