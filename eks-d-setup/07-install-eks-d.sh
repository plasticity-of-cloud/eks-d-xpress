#!/bin/bash
set -e

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

echo "Detected architecture: $ARCH"

# Load EKS version information
if [ -f "/opt/eks-d/version.env" ]; then
  source /opt/eks-d/version.env
  echo "Using stored versions: EKS ${EKS_VERSION}, EKS-D ${EKSD_VERSION}"
else
  # Fallback to hardcoded values if version file not found
  echo "Warning: EKS-D version file not found, using fallback values"
  EKS_VERSION="1.35"
  EKSD_VERSION="1.35.8"
fi

# Convert to EKS-D format for manifest lookup
EKSD_VERSION_PARTS=(${EKSD_VERSION//./ })
EKSD_MANIFEST_VERSION="${EKSD_VERSION_PARTS[0]}-${EKSD_VERSION_PARTS[1]}"
EKSD_RELEASE="${EKSD_VERSION_PARTS[2]}"

echo "Installing EKS-D (EKS Distro) ${EKSD_VERSION} for ${ARCH}..."

# Download EKS-D release manifest
echo "Downloading EKS-D release manifest..."
curl -sL "https://distro.eks.amazonaws.com/kubernetes-${EKSD_MANIFEST_VERSION}/kubernetes-${EKSD_MANIFEST_VERSION}-eks-${EKSD_RELEASE}.yaml" \
  -o /tmp/eks-d-release.yaml

# Extract component URLs for the detected architecture
echo "Extracting ${ARCH} binaries..."
KUBEADM_URL=$(grep "bin/linux/${ARCH}/kubeadm" /tmp/eks-d-release.yaml -B 1 | grep "uri:" | awk '{print $2}')
KUBELET_URL=$(grep "bin/linux/${ARCH}/kubelet" /tmp/eks-d-release.yaml -B 1 | grep "uri:" | awk '{print $2}')
KUBECTL_URL=$(grep "bin/linux/${ARCH}/kubectl" /tmp/eks-d-release.yaml -B 1 | grep "uri:" | awk '{print $2}')

echo "Downloading EKS-D binaries..."
if [ -x /usr/local/bin/kubeadm ] && [ -x /usr/local/bin/kubelet ] && [ -x /usr/local/bin/kubectl ]; then
  echo "✓ EKS-D binaries already installed (pre-baked in AMI)"
else
  curl -sL "${KUBEADM_URL}" -o /tmp/kubeadm
  sudo install -o root -g root -m 0755 /tmp/kubeadm /usr/local/bin/kubeadm

  curl -sL "${KUBELET_URL}" -o /tmp/kubelet
  sudo install -o root -g root -m 0755 /tmp/kubelet /usr/local/bin/kubelet

  curl -sL "${KUBECTL_URL}" -o /tmp/kubectl
  sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi

# Create kubelet systemd service
echo "Creating kubelet systemd service..."
sudo mkdir -p /etc/systemd/system/kubelet.service.d

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

echo "Enabling kubelet..."
sudo systemctl daemon-reload
sudo systemctl enable kubelet

echo "Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

echo "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

echo "Loading required kernel modules..."
sudo modprobe nf_conntrack
sudo modprobe br_netfilter

echo "Starting containerd..."
sudo systemctl enable containerd
sudo systemctl start containerd

# Install ECR credential provider (pre-built into AMI at /usr/bin/ecr-credential-provider)
echo "Configuring ECR credential provider..."
sudo mkdir -p /etc/kubernetes/credential-provider
sudo tee /etc/kubernetes/credential-provider/config.yaml <<EOFCRED
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr.*.amazonaws.com.cn"
      - "*.dkr.ecr-fips.*.amazonaws.com"
      - "public.ecr.aws"
    defaultCacheDuration: 12h
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOFCRED

echo "✓ ECR credential provider installed"

# If AMI_BUILD, skip kubeadm init (will run on first boot)
if [ "${AMI_BUILD:-}" = "true" ]; then
  echo "⏭ Skipping kubeadm init (AMI build - will run on first boot)"
  rm -f /tmp/kubeadm /tmp/kubelet /tmp/kubectl
  echo "✓ EKS-D binaries installed"
  exit 0
fi

echo "Initializing EKS-D cluster..."

# Extract image tags from the EKS-D release manifest
EKSD_K8S_TAG=$(grep "kubernetes/kube-apiserver" /tmp/eks-d-release.yaml | grep "uri:" | head -1 | sed 's/.*://')
EKSD_ETCD_TAG=$(grep "etcd-io/etcd" /tmp/eks-d-release.yaml | grep "uri:" | head -1 | sed 's/.*://')
EKSD_COREDNS_TAG=$(grep "coredns/coredns" /tmp/eks-d-release.yaml | grep "uri:" | head -1 | sed 's/.*://')
PRIVATE_IP=$(hostname -I | awk '{print $1}')

# Get metadata using IMDSv2
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
AWS_REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/region)
AWS_ACCOUNT_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/dynamic/instance-identity/document | python3 -c "import sys,json; print(json.load(sys.stdin)['accountId'])")

echo "  k8s tag:     ${EKSD_K8S_TAG}"
echo "  etcd tag:    ${EKSD_ETCD_TAG}"
echo "  coredns tag: ${EKSD_COREDNS_TAG}"
echo "  node IP:     ${PRIVATE_IP}"

cat <<EOF | sudo tee /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
imageRepository: public.ecr.aws/eks-distro/kubernetes
kubernetesVersion: ${EKSD_K8S_TAG}
controlPlaneEndpoint: ${PRIVATE_IP}
networking:
  serviceSubnet: 10.96.0.0/12
dns:
  imageRepository: public.ecr.aws/eks-distro/coredns
  imageTag: ${EKSD_COREDNS_TAG}
etcd:
  local:
    imageRepository: public.ecr.aws/eks-distro/etcd-io
    imageTag: ${EKSD_ETCD_TAG}
apiServer:
  extraArgs:
    authentication-token-webhook-config-file: /etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml
  extraVolumes:
    - name: aws-iam-authenticator
      hostPath: /etc/kubernetes/aws-iam-authenticator
      mountPath: /etc/kubernetes/aws-iam-authenticator
      readOnly: true
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs:
    image-credential-provider-config: /etc/kubernetes/credential-provider/config.yaml
    image-credential-provider-bin-dir: /usr/bin
    cloud-provider: external
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
rotateCertificates: true
EOF

sudo kubeadm init \
  --config /tmp/kubeadm-config.yaml \
  --ignore-preflight-errors=NumCPU,DirAvailable--var-lib-etcd \
  --v=5 || {
  echo "Warning: kubeadm init had non-critical errors, but cluster may still be functional"
  # Check if cluster is actually working
  if sudo kubectl get nodes --kubeconfig /etc/kubernetes/admin.conf >/dev/null 2>&1; then
    echo "✓ Cluster is functional despite kubeadm warnings"
  else
    echo "✗ Cluster initialization failed"
    exit 1
  fi
}

echo "Setting up kubeconfig..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Cleanup
rm -f /tmp/eks-d-release.yaml /tmp/kubeadm /tmp/kubelet /tmp/kubectl /tmp/kubeadm-config.yaml

echo "✓ EKS-D installed"

# Approve kubelet serving CSR (serverTLSBootstrap generates a CSR with node private IP as SAN)
echo "Approving kubelet serving certificate CSR..."
for i in $(seq 1 30); do
  PENDING=$(kubectl get csr -o jsonpath='{range .items[?(@.status.conditions==null)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
  if [ -n "$PENDING" ]; then
    kubectl certificate approve "$PENDING"
    echo "✓ Approved kubelet serving CSR: $PENDING"
    break
  fi
  [ "$i" -eq 30 ] && echo "Warning: No pending kubelet CSR found after 30s"
  sleep 1
done

# Copy admin.conf for root so all subsequent scripts can use kubectl without --kubeconfig
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

kubectl version --client
kubectl get nodes

# Wait for kube-proxy to program ClusterIP iptables/nftables rules.
# On cold boot, kube-proxy takes ~30s to sync informers and program rules.
# Without this, aws-node (CNI) crashes trying to reach the API server via ClusterIP.
echo "Waiting for kube-proxy to program service routing rules..."
KUBE_SVC_IP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
for i in $(seq 1 60); do
  if curl -sk --connect-timeout 2 "https://${KUBE_SVC_IP}:443/version" >/dev/null 2>&1; then
    echo "✓ kube-proxy rules active (ClusterIP ${KUBE_SVC_IP} routable)"
    break
  fi
  [ "$i" -eq 60 ] && echo "Warning: kube-proxy rules not confirmed after 60s, proceeding anyway"
  sleep 1
done
