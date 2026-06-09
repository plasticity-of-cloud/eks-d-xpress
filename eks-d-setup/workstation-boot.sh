#!/bin/bash
# workstation-boot.sh - EKS-DX Workstation Boot Script
# 
# This script is the entry point for AMI-based EKS-DX workstation deployment.
# It runs automatically via systemd (eks-dx-boot.service) after network-online.target
# and performs idempotent installation of EKS-D and all required components.

set -eo pipefail

# Logging setup
BOOT_LOG="/var/log/eks-dx-boot.log"
exec > >(tee -a "$BOOT_LOG") 2>&1

# EBS warmup — pre-fault the first 256MB of the root volume from snapshot in the
# background so EBS blocks are hot before kubeadm starts (~30s head start).
dd if=/dev/xvda of=/dev/null bs=1M count=256 iflag=direct 2>/dev/null &

# Wait for IMDS + network readiness — bootstrapping during "Initializing" causes
# EC2 API failures and unreliable ENI responses.
echo "Waiting for network readiness..."
for i in $(seq 1 15); do
  TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" -m 2 2>/dev/null || true)
  [ -n "$TOKEN" ] && curl -sf -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id >/dev/null 2>&1 && \
    { echo "✓ IMDS reachable, network ready"; break; }
  [ "$i" -eq 15 ] && echo "Warning: IMDS not confirmed after 15s, proceeding"
  sleep 1
done

echo "=========================================="
echo "EKS-DX Workstation Boot Started"
echo "Time: $(date)"
echo "=========================================="

# Check if installation already completed
if [ -f /opt/eks-d/.installation_complete ]; then
  echo "✓ EKS-DX installation already completed, skipping"
  # kubeadm re-applies the control-plane taint on every node restart;
  # remove it so EBS CSI and Karpenter can schedule on the control-plane node.
  echo "Removing control-plane taint (re-applied by kubeadm on reboot)..."
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
  echo "✓ Control-plane taint removed"
  exit 0
fi

# Ensure we have the required environment
TENANT_ID="${1:-}"
CLUSTER_NAME="${2:-}"

# Fall back to cluster.env if args not provided (manual invocation)
if [ -f /opt/eks-d/cluster.env ]; then
  source /opt/eks-d/cluster.env
fi
# Args take precedence over cluster.env (Terraform user data path)
[ -n "${1:-}" ] && TENANT_ID="$1"
[ -n "${2:-}" ] && CLUSTER_NAME="$2"

# Optional: EKS-DX Pod Identity integration
# Set both via EC2 user data to enable cluster self-registration and component install.
# EKS_DX_ENDPOINT  — Lambda Function URL base (e.g. https://<id>.lambda-url.us-east-1.on.aws)
# EKS_DX_API_URL   — API Gateway URL (e.g. https://<id>.execute-api.us-east-1.amazonaws.com/prod)
EKS_DX_ENDPOINT="${EKS_DX_ENDPOINT:-}"
EKS_DX_API_URL="${EKS_DX_API_URL:-}"

if [ -z "${TENANT_ID}" ] || [ -z "${CLUSTER_NAME}" ]; then
  echo "Error: TENANT_ID and CLUSTER_NAME are required (pass as args or set in /opt/eks-d/cluster.env)"
  exit 1
fi

echo "Developer: ${TENANT_ID}"
echo "Cluster: ${CLUSTER_NAME}"

# Verify installation scripts are available
if [ ! -d /opt/eks-d-setup ]; then
  echo "Error: /opt/eks-d-setup directory not found"
  echo "Installation scripts should be copied during AMI build"
  exit 1
fi

# Run boot-time cluster setup
echo "Starting EKS-D cluster setup..."
cd /opt/eks-d-setup
bash setup-eks-d.sh 2>&1 | tee /var/log/eks-dx-install-all.log

# Copy kubeconfig for the login user (cloud-init runs as root; ec2-user needs access too)
LOGIN_USER="ec2-user"
LOGIN_HOME=$(getent passwd "${LOGIN_USER}" | cut -d: -f6)
if [ -n "${LOGIN_HOME}" ] && [ -f /etc/kubernetes/admin.conf ]; then
  mkdir -p "${LOGIN_HOME}/.kube"
  cp /etc/kubernetes/admin.conf "${LOGIN_HOME}/.kube/config"
  chown -R "${LOGIN_USER}:${LOGIN_USER}" "${LOGIN_HOME}/.kube"
  echo "✓ kubeconfig copied for ${LOGIN_USER}"
fi

# Mark installation as complete
touch /opt/eks-d/.installation_complete
echo "$(date): Installation completed successfully" >> /opt/eks-d/.installation_complete

echo "=========================================="
echo "✓ EKS-DX Workstation Boot Completed"
echo "Time: $(date)"
echo "=========================================="

# Display cluster status
echo ""
echo "Cluster Status:"
kubectl get nodes
echo ""
kubectl get pods -A | grep -E "(Running|Ready)"
