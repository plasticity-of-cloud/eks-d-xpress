#!/bin/bash
set -e

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"

# Fall back to persisted cluster identity
if [ -z "$CLUSTER_NAME" ]; then
  [ -f /opt/eks-d/cluster.env ] && source /opt/eks-d/cluster.env
fi

# Get region via IMDSv2
if [ -z "$AWS_REGION" ]; then
  TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token 2>/dev/null || true)
  AWS_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
fi

if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
  echo "ERROR: CLUSTER_NAME and AWS_REGION must be set" >&2; exit 1
fi

# Wait for kube-proxy to be ready so ClusterIP routing (10.96.0.1) is functional
# before the CloudWatch operator starts — otherwise it can't reach the API server
echo "Waiting for kube-proxy to be ready..."
kubectl wait --for=condition=ready pod -l k8s-app=kube-proxy -n kube-system --timeout=30s

echo "Installing CloudWatch Observability agent..."

CHART=$(ls /opt/eks-d/charts/amazon-cloudwatch-observability-*.tgz 2>/dev/null | head -1)
if [ -z "$CHART" ]; then
  helm repo add aws-observability https://aws-observability.github.io/helm-charts 2>/dev/null || true
  helm repo update
  CHART="aws-observability/amazon-cloudwatch-observability"
fi

helm upgrade --install amazon-cloudwatch-observability "$CHART" \
  --namespace amazon-cloudwatch \
  --create-namespace \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${AWS_REGION}" \
  --set k8sMode=K8S \
  --set manager.applicationSignals.autoMonitor.monitorAllServices=false \
  --set-json 'agent.config={"logs":{"metrics_collected":{"kubernetes":{"enhanced_container_insights":true,"kubelet_https_verify":false}}},"traces":{"traces_collected":{"application_signals":{}}}}' \
  --wait

echo "✓ CloudWatch agent installed"
kubectl get pods -n amazon-cloudwatch
