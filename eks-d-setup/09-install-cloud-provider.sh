#!/bin/bash
set -e

[ -f /opt/eks-d/cluster.env ] && source /opt/eks-d/cluster.env

echo "Installing AWS Cloud Provider..."

CHART=$(ls /opt/eks-d/charts/aws-cloud-controller-manager-*.tgz 2>/dev/null | head -1)
if [ -z "$CHART" ]; then
  helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
  helm repo update
  CHART="aws-cloud-controller-manager/aws-cloud-controller-manager"
fi

helm upgrade --install aws-cloud-controller-manager "$CHART" \
  --namespace kube-system \
  --set nodeSelector."node-role\.kubernetes\.io/control-plane"="" \
  --set tolerations[0].key="node-role.kubernetes.io/control-plane" \
  --set tolerations[0].effect="NoSchedule" \
  --set args[0]=--v=2 \
  --set args[1]=--cloud-provider=aws \
  --set args[2]=--configure-cloud-routes=false \
  --set args[3]=--cluster-name="${CLUSTER_NAME}" \
  --wait

# The chart doesn't support hostNetwork via values — patch directly.
# Required so the pod can reach IMDS at 169.254.169.254 (link-local).
kubectl patch daemonset aws-cloud-controller-manager -n kube-system \
  --patch '{"spec":{"template":{"spec":{"hostNetwork":true}}}}'

echo "✓ AWS Cloud Provider installed"

# Wait for cloud controller manager to be ready
echo "Waiting for cloud controller manager to be ready (timeout: 30s)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=aws-cloud-controller-manager -n kube-system --timeout=30s || {
  echo "Warning: Cloud controller manager timeout, but it may still become ready"
}

# Wait for cloud controller manager to initialize the node
echo "Waiting for cloud controller manager to initialize node..."
sleep 10

# Remove the uninitialized taint so system pods can schedule
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
if kubectl get node "$NODE_NAME" -o jsonpath='{.spec.taints[*].key}' | grep -q "node.cloudprovider.kubernetes.io/uninitialized"; then
  echo "Removing cloud provider uninitialized taint from node $NODE_NAME..."
  kubectl taint nodes "$NODE_NAME" node.cloudprovider.kubernetes.io/uninitialized- || {
    echo "Warning: Could not remove cloud provider taint, but it may have been removed already"
  }
  echo "✓ Cloud provider taint removed"
else
  echo "✓ Cloud provider taint not present or already removed"
fi
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cloud-controller-manager
