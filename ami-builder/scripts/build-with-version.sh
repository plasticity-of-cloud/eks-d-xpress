#!/bin/bash
set -e

# EKS-D Version Selection for AMI Build
# This script allows customers to select Kubernetes version during AMI build

echo "=========================================="
echo "EKS-D Version Selection"
echo "=========================================="
echo ""

# Available versions (update as new versions become available)
AVAILABLE_VERSIONS=("1.35" "1.36")

if [ -n "$1" ]; then
  KUBERNETES_VERSION="$1"
else
  echo "Available Kubernetes versions:"
  for i in "${!AVAILABLE_VERSIONS[@]}"; do
    echo "  $((i+1)). ${AVAILABLE_VERSIONS[$i]}"
  done
  echo ""
  read -p "Select Kubernetes version (1-${#AVAILABLE_VERSIONS[@]}): " choice
  
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#AVAILABLE_VERSIONS[@]}" ]; then
    KUBERNETES_VERSION="${AVAILABLE_VERSIONS[$((choice-1))]}"
  else
    echo "Invalid selection. Using default: 1.35"
    KUBERNETES_VERSION="1.35"
  fi
fi

echo "Selected Kubernetes version: $KUBERNETES_VERSION"
echo ""

# Export for use by install.sh
export KUBERNETES_VERSION

# Run the main installation
exec "$(dirname "$0")/install.sh"
