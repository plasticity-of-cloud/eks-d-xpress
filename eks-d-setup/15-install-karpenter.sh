#!/bin/bash
set -e

# Source environment variables first
[ -f /opt/eks-d/cluster.env ] && source /opt/eks-d/cluster.env

TENANT_ID="${1:-${TENANT_ID:-}}"
CLUSTER_NAME="${2:-${CLUSTER_NAME:-}}"

if [ -z "$TENANT_ID" ] || [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <tenant-id> <cluster-name>"
  exit 1
fi

if [ -z "$TENANT_ID" ] || [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <tenant-id> <cluster-name>"
  exit 1
fi

if [ -z "$AWS_REGION" ] || [ -z "$AWS_ACCOUNT_ID" ]; then
  echo "Error: AWS environment variables not found in /opt/eks-d/cluster.env"
  exit 1
fi

CLUSTER_ENDPOINT="https://${NODE_IP}:6443"

# On EKS-D, there is no EKS managed control plane — Karpenter cannot use DescribeCluster.
# clusterEndpoint must be set explicitly to the API server address.

# Source versions from central config
[ -f /opt/eks-d/manifests/eks-d-versions.env ] && source /opt/eks-d/manifests/eks-d-versions.env
KARPENTER_VERSION="${KARPENTER_VERSION:-1.13.0}"

echo "Installing Karpenter ${KARPENTER_VERSION}..."
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"

# Karpenter moved to OCI registry — helm repo add no longer works
# Logout first to allow unauthenticated pull from public ECR
helm registry logout public.ecr.aws 2>/dev/null || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --set settings.clusterName=${CLUSTER_NAME} \
  --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
  --set settings.interruptionQueue=${CLUSTER_NAME} \
  --set settings.eksControlPlane=false \
  --set replicas=1 \
  --set controller.resources.requests.cpu=200m \
  --set controller.resources.requests.memory=512Mi \
  --set controller.resources.limits.cpu=500m \
  --set controller.resources.limits.memory=512Mi \
  --set topologySpreadConstraints=null \
  --set controller.env[0].name=AWS_REGION \
  --set controller.env[0].value=${AWS_REGION} \
  --wait

echo "✓ Karpenter installed"

echo "Waiting for Karpenter controller to be ready (timeout: 30s)..."
kubectl wait --for=condition=available --timeout=30s deployment/karpenter -n kube-system || {
  echo "Warning: Karpenter deployment timeout, but it may still become ready"
}

kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
