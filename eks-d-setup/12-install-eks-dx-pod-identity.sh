#!/bin/bash
# 12-install-eks-dx-pod-identity.sh
# Registers the cluster with the EKS-DX control plane and installs Pod Identity components.
#
# Prerequisites: cert-manager (11-install-cert-manager.sh)
# Required env (via /opt/eks-d/cluster.env):
#   EKS_DX_ENDPOINT, CLUSTER_NAME, AWS_REGION
set -eo pipefail

[ -f /opt/eks-d/cluster.env ] && source /opt/eks-d/cluster.env
[ -f /opt/eks-d/version.env ] && source /opt/eks-d/version.env

if [ -z "${EKS_DX_ENDPOINT:-}" ]; then
  echo "Skipping EKS-DX Pod Identity (EKS_DX_ENDPOINT not set)"
  exit 0
fi

: "${CLUSTER_NAME:?CLUSTER_NAME not set}"
: "${AWS_REGION:?AWS_REGION not set}"

echo "Step 6c: Registering with EKS-DX control plane..."

# Extract JWKS from the running cluster
JWKS=$(kubectl get --raw /openid/v1/jwks)

# Register cluster with EKS-DX control plane
REGISTRATION_PAYLOAD=$(jq -n \
  --arg cluster "$CLUSTER_NAME" \
  --arg region "$AWS_REGION" \
  --argjson jwks "$JWKS" \
  '{cluster_name: $cluster, region: $region, jwks: $jwks}')

curl -fsSL -X POST "${EKS_DX_ENDPOINT}/clusters/register" \
  -H "Content-Type: application/json" \
  --aws-sigv4 "aws:amz:${AWS_REGION}:lambda" \
  --user "$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/))" \
  -d "$REGISTRATION_PAYLOAD" \
  -o /tmp/eks-dx-registration.json

ISSUER_URL=$(jq -r '.issuer_url' /tmp/eks-dx-registration.json)
: "${ISSUER_URL:?Registration failed — no issuer_url in response}"
echo "✓ Cluster registered, issuer: $ISSUER_URL"

# Install eks-dx-pod-identity-webhook via Helm
CHART=$(ls /opt/eks-d/charts/eks-dx-pod-identity-webhook-*.tgz 2>/dev/null | head -1)
if [ -z "$CHART" ]; then
  echo "Error: eks-dx-pod-identity-webhook chart not found in /opt/eks-d/charts/" >&2
  exit 1
fi

helm upgrade --install eks-dx-pod-identity-webhook "$CHART" \
  --namespace kube-system \
  --set issuerUrl="$ISSUER_URL" \
  --set clusterName="$CLUSTER_NAME" \
  --wait --timeout=120s

echo "✓ EKS-DX Pod Identity webhook installed"

kubectl get pods -n kube-system -l app.kubernetes.io/name=eks-dx-pod-identity-webhook
