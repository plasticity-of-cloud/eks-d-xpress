#!/bin/bash
# setup-eks-d.sh - Boot-time EKS-D cluster setup
#
# Assumes AMI-baked prerequisites are already present:
#   containerd, helm, kubectl, kubeadm, kubelet, ECR credential provider,
#   all container images pre-pulled.
#
# Runs: etcd volume → iam-authenticator → kubeadm init → CNI → CCM →
#       node config → EBS CSI → metrics-server → Karpenter → CloudWatch
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── cluster.env is written by TenantEc2Service before instance launch ─────────
if [ ! -f /opt/eks-d/cluster.env ]; then
  echo "Error: /opt/eks-d/cluster.env not found (expected to be pre-seeded by TenantEc2Service)"
  exit 1
fi
source /opt/eks-d/cluster.env

# ── Load progress reporting ───────────────────────────────────────────────────
source "${SCRIPT_DIR}/progress.sh"
trap 'fail "Unexpected error at line ${LINENO}: ${BASH_COMMAND}"' ERR

echo "✓ cluster.env loaded (tenant=${TENANT_ID}, cluster=${CLUSTER_NAME}, node-ip=${NODE_IP})"

echo "=========================================="
echo "EKS-D Cluster Setup"
echo "Developer: ${TENANT_ID}  Cluster: ${CLUSTER_NAME}"
echo "=========================================="
update_progress "booting" "Starting cluster setup" 5

# Step 1: etcd volume (EBS attached at instance launch)
echo "Step 1/10: Preparing etcd volume..."
bash "${SCRIPT_DIR}/05-prepare-etcd.sh"
update_progress "provisioning" "Preparing etcd volume" 10

# Step 2: aws-iam-authenticator config (must precede kubeadm init)
echo "Step 2/10: Configuring aws-iam-authenticator..."
bash "${SCRIPT_DIR}/06-install-aws-iam-authenticator.sh"
update_progress "provisioning" "Configuring IAM authenticator" 15

# Step 3: kubeadm init
echo "Step 3/10: Initialising EKS-D cluster..."
update_progress "kubeadm-init" "Initialising control plane" 20
bash "${SCRIPT_DIR}/07-install-eks-d.sh"
update_progress "kubeadm-done" "Control plane ready" 40

# Make kubeconfig available to the login user immediately after kubeadm init
# (systemd runs this as root; without this ec2-user is locked out if any later step fails)
_LOGIN_USER="ec2-user"
_LOGIN_HOME=$(getent passwd "${_LOGIN_USER}" | cut -d: -f6)
if [ -n "${_LOGIN_HOME}" ] && [ -f /etc/kubernetes/admin.conf ]; then
  mkdir -p "${_LOGIN_HOME}/.kube"
  cp /etc/kubernetes/admin.conf "${_LOGIN_HOME}/.kube/config"
  chown -R "${_LOGIN_USER}:${_LOGIN_USER}" "${_LOGIN_HOME}/.kube"
  echo "✓ kubeconfig copied to ${_LOGIN_USER}"
fi

# kube-proxy readiness is already confirmed by 07-install-eks-d.sh (polls ClusterIP).

# Step 4: AWS VPC CNI
echo "Step 4/10: Installing AWS VPC CNI..."
update_progress "provisioning" "Installing VPC CNI" 50
bash "${SCRIPT_DIR}/08-install-cni.sh"
update_progress "provisioning" "VPC CNI installed" 55

# Step 5: AWS Cloud Controller Manager
echo "Step 5/10: Installing AWS Cloud Provider..."
update_progress "provisioning" "Installing cloud provider" 58
bash "${SCRIPT_DIR}/09-install-cloud-provider.sh"
update_progress "provisioning" "Cloud provider installed" 62

# Step 6: Untaint control plane
echo "Step 6/10: Configuring control plane node..."
bash "${SCRIPT_DIR}/10-configure-node.sh"
update_progress "provisioning" "Node ready" 65

# Step 6b: cert-manager (required by webhooks and observability)
echo "Step 6b: Installing cert-manager..."
bash "${SCRIPT_DIR}/11-install-cert-manager.sh"
update_progress "provisioning" "cert-manager installed" 70

# Step 6b2: kubelet CSR auto-approver (replicates EKS node-joining / serving cert approval)
echo "Step 6b2: Deploying kubelet-csr-approver..."
bash "${SCRIPT_DIR}/11b-install-kubelet-csr-approver.sh"
update_progress "provisioning" "kubelet-csr-approver deployed" 71

# Step 6c: EKS-DX Pod Identity integration (requires cert-manager for webhook TLS)
# Only runs if EKS_DX_ENDPOINT is set (provisioned by Lambda, not manual dev setup)
if [ -n "${EKS_DX_ENDPOINT:-}" ]; then
  echo "Step 6c: Registering with EKS-DX control plane..."
  update_progress "registering" "Registering cluster with EKS-DX" 72
  bash "${SCRIPT_DIR}/12-install-eks-dx-pod-identity.sh"
else
  echo "Step 6c: Skipping EKS-DX Pod Identity (EKS_DX_ENDPOINT not set — manual/dev mode)"
fi

# Step 7: EBS CSI Driver
echo "Step 7/10: Installing EBS CSI Driver..."
bash "${SCRIPT_DIR}/13-install-ebs-csi.sh"
update_progress "provisioning" "EBS CSI installed" 75

# Step 8: Metrics Server
echo "Step 8/10: Installing Metrics Server..."
bash "${SCRIPT_DIR}/14-install-metrics-server.sh"
update_progress "provisioning" "Metrics server installed" 80

# Step 9: Karpenter
echo "Step 9/10: Installing Karpenter..."
bash "${SCRIPT_DIR}/15-install-karpenter.sh" "${TENANT_ID}" "${CLUSTER_NAME}"
update_progress "provisioning" "Karpenter installed" 90

# Step 10: CloudWatch
echo "Step 10/10: Installing CloudWatch agent..."
CLUSTER_NAME="${CLUSTER_NAME}" bash "${SCRIPT_DIR}/16-install-cloudwatch.sh"
update_progress "provisioning" "CloudWatch installed" 95

# Deferred CloudWatch validation — operator has had time to reconcile by now
bash "${SCRIPT_DIR}/17-monitor-cloudwatch-rollout.sh"

echo ""
echo "=========================================="
echo "✓ EKS-D cluster setup complete!"
echo "=========================================="
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo "  cd ../node-pools && ./configure-nodepools.sh ${TENANT_ID}"

report_ready
