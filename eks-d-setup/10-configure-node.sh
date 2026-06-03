#!/bin/bash
set -e

echo "Untainting control plane node..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "✓ Control plane configured"
kubectl get nodes
