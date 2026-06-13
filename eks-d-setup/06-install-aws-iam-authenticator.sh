#!/bin/bash
# 05b-install-aws-iam-authenticator.sh
#
# Creates the three files required by the API server's webhook authentication
# before kubeadm init runs. Must execute AFTER 05-prepare-etcd.sh and
# BEFORE 06-install-eks-d.sh.
#
# Why this must run before kubeadm init
# ──────────────────────────────────────
# 06-install-eks-d.sh passes
#   --authentication-token-webhook-config-file=/etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml
# to the API server via kubeadm ClusterConfiguration.extraArgs.
# kubeadm bakes that flag into the kube-apiserver static pod manifest.
# If the file is absent when the API server pod starts, it crashes immediately
# and kubeadm init never completes.
#
# Files created
# ─────────────
# /etc/kubernetes/aws-iam-authenticator/config.yaml
#   Authenticator server config: maps the workstation IAM role to
#   system:node:<hostname> in the system:nodes group.
#   Karpenter-provisioned worker nodes assume this same role, so they
#   authenticate automatically without any additional role mapping.
#
# /etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml
#   Webhook kubeconfig consumed by the API server.
#   Points to https://localhost:21362/authenticate (authenticator's default port).
#   Uses insecure-skip-tls-verify because the authenticator generates a
#   self-signed cert; the connection is loopback-only so this is acceptable.
#
# /etc/kubernetes/manifests/aws-iam-authenticator.yaml
#   Static pod manifest. kubelet starts this pod alongside the API server.
#   The pod mounts the config dir and a state dir where it stores its TLS cert.
#   --kubeconfig-pregenerated=true prevents the authenticator from overwriting
#   the kubeconfig.yaml we already wrote above.
#
# IAM role mapping
# ────────────────
# Both the control-plane EC2 instance and Karpenter worker nodes use the
# same IAM instance profile: eks-dx-workstation-<signum>.
# The authenticator maps that role to:
#   username: system:node:{{EC2PrivateDNSName}}
#   groups:   [system:bootstrappers, system:nodes]
# This satisfies the Node Authorizer so worker nodes can register and pull
# their kubelet config from the API server.

set -e

# ── Identity and AWS Environment ──────────────────────────────────────────────
[ -f /opt/eks-d/cluster.env ] && source /opt/eks-d/cluster.env

if [ -z "${TENANT_ID}" ] || [ -z "${CLUSTER_NAME}" ]; then
  echo "Error: TENANT_ID and CLUSTER_NAME must be set."
  echo "       Run install-all.sh <signum> or source /opt/eks-d/cluster.env first."
  exit 1
fi

if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$AWS_REGION" ]; then
  echo "Error: AWS environment variables not found in /opt/eks-d/cluster.env"
  exit 1
fi

_ARCH="$(uname -m | sed 's/aarch64/arm64/')"
NODE_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/eks-d-xpress-tenant-${TENANT_ID}-instance-role"

# ── EKS-D image registry ──────────────────────────────────────────────────────
if [ ! -f /opt/eks-d/manifests/eks-d-versions.env ]; then
  echo "Error: /opt/eks-d/manifests/eks-d-versions.env not found."
  echo "       This file is generated during AMI build by discover-eks-d.sh."
  exit 1
fi
source /opt/eks-d/manifests/eks-d-versions.env

if [ -z "${AWS_IAM_AUTHENTICATOR_IMAGE}" ]; then
  echo "Error: AWS_IAM_AUTHENTICATOR_IMAGE not found in eks-d-versions.env"
  exit 1
fi

echo "Configuring aws-iam-authenticator..."
echo "  Cluster:   ${CLUSTER_NAME}"
echo "  Region:    ${AWS_REGION}"
echo "  Node role: ${NODE_ROLE_ARN}"
echo "  Image:     ${AWS_IAM_AUTHENTICATOR_IMAGE}"

# Ensure required directories exist
sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /etc/kubernetes/aws-iam-authenticator
# The authenticator image runs as a non-root user; the state dir must be world-writable
# so it can write its TLS cert and key on first start.
sudo mkdir -p /var/aws-iam-authenticator
sudo chmod 777 /var/aws-iam-authenticator

# ── 1. Authenticator server config ───────────────────────────────────────────
# clusterID must match the value used when clients generate their tokens.
# mapRoles entries use exact ARNs — wildcards are not supported.
# {{EC2PrivateDNSName}} is a template variable resolved by the authenticator
# at runtime using the STS GetCallerIdentity response.
cat <<EOF | sudo tee /etc/kubernetes/aws-iam-authenticator/config.yaml
clusterID: ${CLUSTER_NAME}
server:
  mapRoles:
    - roleARN: ${NODE_ROLE_ARN}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF

# ── 2. Webhook kubeconfig (consumed by kube-apiserver) ───────────────────────
# The API server calls this endpoint for every bearer token it cannot
# validate itself. The authenticator listens on 21362 (hostNetwork: true).
cat <<EOF | sudo tee /etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
  - name: aws-iam-authenticator
    cluster:
      server: https://localhost:21362/authenticate
      insecure-skip-tls-verify: true
users:
  - name: kube-apiserver
contexts:
  - name: aws-iam-authenticator
    context:
      cluster: aws-iam-authenticator
      user: kube-apiserver
current-context: aws-iam-authenticator
EOF

# ── 3. Static pod manifest ────────────────────────────────────────────────────
# hostNetwork: true — shares the host network namespace so the authenticator
# is reachable on localhost:21362 before any CNI is installed.
# --kubeconfig-pregenerated=true — do not overwrite the kubeconfig we wrote above.
cat <<EOF | sudo tee /etc/kubernetes/manifests/aws-iam-authenticator.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aws-iam-authenticator
  namespace: kube-system
  labels:
    app: aws-iam-authenticator
spec:
  hostNetwork: true
  containers:
    - name: aws-iam-authenticator
      image: ${AWS_IAM_AUTHENTICATOR_IMAGE}
      args:
        - server
        - --config=/etc/aws-iam-authenticator/config.yaml
        - --state-dir=/var/aws-iam-authenticator
        - --generate-kubeconfig=/etc/aws-iam-authenticator/kubeconfig.yaml
        - --kubeconfig-pregenerated=true
      volumeMounts:
        - name: config
          mountPath: /etc/aws-iam-authenticator
        - name: state
          mountPath: /var/aws-iam-authenticator
  volumes:
    - name: config
      hostPath:
        path: /etc/kubernetes/aws-iam-authenticator
    - name: state
      hostPath:
        path: /var/aws-iam-authenticator
        type: DirectoryOrCreate
EOF

echo "✓ aws-iam-authenticator configured"
