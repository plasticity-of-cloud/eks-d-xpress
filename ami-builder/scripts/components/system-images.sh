#!/bin/bash
# System images that have no Helm chart: metrics-server, aws-iam-authenticator, kubectl
set -e
source /tmp/ami-build.env

echo "  Pulling metrics-server image..."
[ -n "$METRICS_SERVER_IMAGE" ] && \
  sudo ctr -n k8s.io images pull "$METRICS_SERVER_IMAGE" || true

echo "  Pulling aws-iam-authenticator image..."
[ -n "$AWS_IAM_AUTHENTICATOR_IMAGE" ] && \
  sudo ctr -n k8s.io images pull "$AWS_IAM_AUTHENTICATOR_IMAGE" || true

echo "  Pulling kubectl image (for kubelet-csr-approver)..."
sudo ctr -n k8s.io images pull \
  --user "${ECR_CTR_USER}" \
  "${K8S_REGISTRY_CACHE}/kubectl:v1.32.0" || true

echo "✓ system-images ready"
