#!/bin/bash
set -e

# EKS-D Version Discovery and Manifest Generation
# This script discovers the latest EKS-D release for a given Kubernetes version
# and generates component manifests for installation scripts

KUBERNETES_VERSION="${1:-1.35}"
OUTPUT_DIR="${2:-/opt/eks-d/manifests}"

if [[ ! "$KUBERNETES_VERSION" =~ ^1\.[0-9]+$ ]]; then
  echo "Usage: $0 <kubernetes-version> [output-dir]"
  echo "Example: $0 1.35 /opt/eks-d/manifests"
  exit 1
fi

EKSD_VERSION="1-${KUBERNETES_VERSION#1.}"
echo "==> Discovering EKS-D components for Kubernetes ${KUBERNETES_VERSION}..."

# Discover latest release for this version
echo "==> Finding latest release for ${EKSD_VERSION}..."
GITHUB_RELEASES_URL="https://api.github.com/repos/aws/eks-distro/releases"
LATEST_RELEASE=$(curl -s "$GITHUB_RELEASES_URL" | grep -oP "\"tag_name\":\s*\"v${EKSD_VERSION}-eks-\K[0-9]+" | sort -n | tail -1)

if [ -z "$LATEST_RELEASE" ]; then
  echo "ERROR: No releases found for EKS-D ${EKSD_VERSION}"
  echo "Trying fallback method..."
  # Fallback: try common release numbers
  for rel in 8 7 6 5 4 3 2 1; do
    TEST_URL="https://distro.eks.amazonaws.com/kubernetes-${EKSD_VERSION}/kubernetes-${EKSD_VERSION}-eks-${rel}.yaml"
    if curl -s --head "$TEST_URL" | grep -q "200 OK"; then
      LATEST_RELEASE="$rel"
      break
    fi
  done
  
  if [ -z "$LATEST_RELEASE" ]; then
    echo "ERROR: Could not find any valid release for ${EKSD_VERSION}"
    exit 1
  fi
fi

EKSD_RELEASE="$LATEST_RELEASE"
MANIFEST_URL="https://distro.eks.amazonaws.com/kubernetes-${EKSD_VERSION}/kubernetes-${EKSD_VERSION}-eks-${EKSD_RELEASE}.yaml"

echo "==> Found EKS-D ${EKSD_VERSION}-eks-${EKSD_RELEASE}"
echo "==> Downloading manifest from: ${MANIFEST_URL}"

# Create output directory
sudo mkdir -p "$OUTPUT_DIR"

# Download full manifest
curl -s "$MANIFEST_URL" | sudo tee "$OUTPUT_DIR/eks-d-release.yaml" > /dev/null

# Extract component versions and images
echo "==> Extracting component information..."

# Create version info file
cat > /tmp/eks-d-versions.env << EOF
# EKS-D Version Information
# Generated on $(date)
EKSD_VERSION="${EKSD_VERSION}"
EKSD_RELEASE="${EKSD_RELEASE}"
KUBERNETES_VERSION="${KUBERNETES_VERSION}"
MANIFEST_URL="${MANIFEST_URL}"
EOF

# Extract component versions
curl -s "$MANIFEST_URL" | grep -E "^    name:|^    gitTag:" | paste - - | \
  sed 's/    gitTag: //' | sed 's/    name: //' | \
  awk '{
    name = toupper($2)
    gsub(/-/, "_", name)
    print name"_VERSION=\""$1"\""
  }' >> /tmp/eks-d-versions.env

# Extract container images
echo "" >> /tmp/eks-d-versions.env
echo "# Container Images" >> /tmp/eks-d-versions.env
curl -s "$MANIFEST_URL" | grep -oP 'uri: public\.ecr\.aws/[^"]+' | \
  sed 's/uri: //' | sort -u | \
  awk -F'/' '{
    component = $NF
    gsub(/:.*/, "", component)
    gsub(/-/, "_", component)
    print toupper(component)"_IMAGE=\""$0"\""
  }' >> /tmp/eks-d-versions.env

# Move to final location
sudo mv /tmp/eks-d-versions.env "$OUTPUT_DIR/eks-d-versions.env"

echo "==> Component discovery complete!"
echo "    Manifest: $OUTPUT_DIR/eks-d-release.yaml"
echo "    Versions: $OUTPUT_DIR/eks-d-versions.env"

# Show discovered components
echo ""
echo "==> Discovered components:"
grep "_VERSION=" "$OUTPUT_DIR/eks-d-versions.env" | sed 's/_VERSION=/: /' | sed 's/"//g'

echo ""
echo "==> Container images:"
grep "_IMAGE=" "$OUTPUT_DIR/eks-d-versions.env" | wc -l | xargs echo "Found" | sed 's/$/ images/'
