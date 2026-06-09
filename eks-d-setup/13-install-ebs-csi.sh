#!/bin/bash
set -e

echo "Installing EBS CSI Driver v1.38.0 via Helm..."
CHART=$(ls /opt/eks-d-setup/charts/aws-ebs-csi-driver-*.tgz 2>/dev/null | head -1)
if [ -z "$CHART" ]; then
  helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
  helm repo update
  CHART="aws-ebs-csi-driver/aws-ebs-csi-driver"
fi

# Get cluster name and AWS variables from persisted identity
[ -f /opt/eks-d/cluster.env ] && source /opt/eks-d/cluster.env

if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
  echo "Error: Required variables not found in /opt/eks-d/cluster.env"
  exit 1
fi

helm upgrade --install aws-ebs-csi-driver "$CHART" \
  --namespace kube-system \
  --set controller.serviceAccount.create=true \
  --set controller.k8sTagClusterId="$CLUSTER_NAME" \
  --set controller.replicaCount=1 \
  --set controller.region="$AWS_REGION" \
  --set node.enableWindows=false \
  --wait

# Instance is already tagged with ebs.csi.aws.com/cluster-name by TenantEc2Service at launch time.

echo "Creating default storage class..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

echo "✓ EBS CSI Driver installed with cluster-scoped policy"

echo "Waiting for EBS CSI node pods to be ready (timeout: 30s)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=aws-ebs-csi-driver,app.kubernetes.io/component=csi-driver -n kube-system --timeout=30s || {
  echo "Warning: EBS CSI node pods timeout, but driver may still become ready"
}

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
kubectl get storageclass
