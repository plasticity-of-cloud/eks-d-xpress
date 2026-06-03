#!/bin/bash
set -e

HELM_VERSION="v3.17.3"
ARCH=$(uname -m)
case $ARCH in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Installing Helm ${HELM_VERSION}..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
sudo install -o root -g root -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH}"

echo "✓ Helm installed"
helm version
