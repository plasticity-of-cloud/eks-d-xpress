#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# All values sourced from cluster.env written at boot time by setup-eks-d.sh
if [ ! -f /opt/eks-d/cluster.env ]; then
  echo "ERROR: /opt/eks-d/cluster.env not found. Run this script on the control plane EC2." >&2
  exit 1
fi
source /opt/eks-d/cluster.env

REGION="${AWS_REGION:-us-east-1}"
ARCH="${ARCH:-arm64}"
CLUSTER_NAME="${CLUSTER_NAME:-${TENANT_ID}-eks-dx-${ARCH}}"

# NODE_VARIANT controls which EKS-optimized AMI family to use.
# Supported values:
#   al2023            - Amazon Linux 2023 standard (default)
#   al2023-gpu        - Amazon Linux 2023 + NVIDIA GPU
#   al2023-neuron     - Amazon Linux 2023 + AWS Inferentia/Trainium
#   bottlerocket      - Bottlerocket standard
#   bottlerocket-gpu  - Bottlerocket + NVIDIA GPU
#   bottlerocket-neuron - Bottlerocket + AWS Inferentia/Trainium
NODE_VARIANT="${1:-al2023}"
OUTPUT_DIR="/opt/eks-d/karpenter_runtime_configuration"

echo "Discovering Karpenter configuration for $TENANT_ID (cluster: $CLUSTER_NAME)..."

K8S_MINOR=$(kubectl version --output=json 2>/dev/null | python3 -c "import sys,json; v=json.load(sys.stdin)['serverVersion']['minor']; print(v.rstrip('+'))")

# Resolve SSM parameter path based on NODE_VARIANT
case "$NODE_VARIANT" in
  al2023)
    SSM_PATH="/aws/service/eks/optimized-ami/1.${K8S_MINOR}/amazon-linux-2023/${ARCH}/standard/recommended/image_id" ;;
  al2023-gpu)
    SSM_PATH="/aws/service/eks/optimized-ami/1.${K8S_MINOR}/amazon-linux-2023/${ARCH}/nvidia/recommended/image_id" ;;
  al2023-neuron)
    SSM_PATH="/aws/service/eks/optimized-ami/1.${K8S_MINOR}/amazon-linux-2023/${ARCH}/neuron/recommended/image_id" ;;
  bottlerocket)
    SSM_PATH="/aws/service/bottlerocket/aws-k8s-${K8S_MINOR}/${ARCH}/latest/image_id" ;;
  bottlerocket-gpu)
    SSM_PATH="/aws/service/bottlerocket/aws-k8s-${K8S_MINOR}-nvidia/${ARCH}/latest/image_id" ;;
  bottlerocket-neuron)
    SSM_PATH="/aws/service/bottlerocket/aws-k8s-${K8S_MINOR}-neuron/${ARCH}/latest/image_id" ;;
  *)
    echo "Unknown NODE_VARIANT: $NODE_VARIANT"; exit 1 ;;
esac

AMI_ID=$(aws ssm get-parameter --name "$SSM_PATH" \
  --query Parameter.Value --output text --region "$REGION")
echo "  Node variant      : $NODE_VARIANT"
echo "  EKS-Optimized AMI : $AMI_ID (k8s 1.${K8S_MINOR} ${ARCH})"

# Discover AWS resources
# Instance profile follows the same naming convention as the role
INSTANCE_PROFILE="${TENANT_ID}-eks-dx-${ARCH}"

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Developer,Values=${TENANT_ID}" "Name=tag:SubnetType,Values=Private" \
  --query 'Subnets[0].SubnetId' --output text --region "$REGION")

SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${TENANT_ID}-eks-dx-${ARCH}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION")

# Discover cluster details
API_SERVER="https://$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}'):6443"
CA_BUNDLE=$(sudo cat /etc/kubernetes/pki/ca.crt 2>/dev/null | base64 -w0 || \
            kubectl get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)
SERVICE_CIDR=$(kubectl get configmap kubeadm-config -n kube-system \
  -o jsonpath='{.data.ClusterConfiguration}' | grep serviceSubnet | awk '{print $2}')
# Compute cluster DNS IP: 10th IP of service CIDR (e.g. 10.96.0.0/12 → 10.96.0.10)
CLUSTER_DNS_IP=$(python3 -c "
import ipaddress, sys
net = ipaddress.ip_network('${SERVICE_CIDR}', strict=False)
print(str(list(net.hosts())[9]))
")

echo "  Instance Profile : $INSTANCE_PROFILE"
echo "  Subnet           : $SUBNET_ID"
echo "  Security Group   : $SECURITY_GROUP_ID"
echo "  API Server       : $API_SERVER"
echo "  Service CIDR     : $SERVICE_CIDR"
echo "  Cluster DNS IP   : $CLUSTER_DNS_IP"

# Render chart and persist
sudo mkdir -p "$OUTPUT_DIR"

helm template eks-d-karpenter "${SCRIPT_DIR}/chart" \
  --set clusterName="$CLUSTER_NAME" \
  --set tenantId="$TENANT_ID" \
  --set awsRegion="$REGION" \
  --set amiId="$AMI_ID" \
  --set nodeVariant="$NODE_VARIANT" \
  --set instanceProfile="$INSTANCE_PROFILE" \
  --set subnetId="$SUBNET_ID" \
  --set securityGroupId="$SECURITY_GROUP_ID" \
  --set nodeConfig.apiServerEndpoint="$API_SERVER" \
  --set nodeConfig.certificateAuthority="$CA_BUNDLE" \
  --set nodeConfig.serviceCidr="$SERVICE_CIDR" \
  --set nodeConfig.clusterDnsIp="$CLUSTER_DNS_IP" \
  | sudo tee "$OUTPUT_DIR/karpenter-manifests.yaml" > /dev/null

echo "✓ Rendered manifests saved to $OUTPUT_DIR/karpenter-manifests.yaml"

# Apply
kubectl apply -f "$OUTPUT_DIR/karpenter-manifests.yaml"

echo "✓ NodePool and EC2NodeClass applied."
echo "  To re-apply without re-discovery: kubectl apply -f $OUTPUT_DIR/karpenter-manifests.yaml"
