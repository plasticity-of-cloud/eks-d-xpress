#!/bin/bash
set -e

# EKS-D AMI Installation Script
# Pre-installs binaries, images, and scripts for fast workstation boot

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EKS_D_SETUP_DIR="/tmp/eks-d-setup"

# EKS-D version — passed from build-control-plane-ami.sh via KUBERNETES_VERSION env var
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35}"
EKS_VERSION="${KUBERNETES_VERSION}"

echo "==> Discovering EKS-D components for Kubernetes ${EKS_VERSION}..."

# Store configuration for later use
sudo mkdir -p /opt/eks-d
echo "EKS_VERSION=${EKS_VERSION}" | sudo tee /opt/eks-d/version.env
echo "TAGGED_AMIS=eks-dx-${EKS_VERSION}" | sudo tee -a /opt/eks-d/version.env

bash "${SCRIPT_DIR}/discover-eks-d.sh" "$EKS_VERSION" "/opt/eks-d/manifests"

# Load discovered versions
source /opt/eks-d/manifests/eks-d-versions.env
echo "==> Using EKS-D ${EKSD_VERSION}-eks-${EKSD_RELEASE}"

# Persist full version info for use by 07-install-eks-d.sh at boot time
EKSD_DOTTED="${EKS_VERSION}.${EKSD_RELEASE}"
echo "EKSD_VERSION=${EKSD_DOTTED}" | sudo tee -a /opt/eks-d/version.env
# Source component versions (single source of truth)
VERSIONS_ENV="${SCRIPT_DIR}/component-versions.env"
[ -f "$VERSIONS_ENV" ] && source "$VERSIONS_ENV"
: "${EKS_DX_CONTROL_PLANE_VERSION:?component-versions.env missing or EKS_DX_CONTROL_PLANE_VERSION not set}"
echo "EKS_DX_CONTROL_PLANE_VERSION=${EKS_DX_CONTROL_PLANE_VERSION}" | sudo tee -a /opt/eks-d/version.env
echo "INSTALL_EKS_DX=${INSTALL_EKS_DX:-false}" | sudo tee -a /opt/eks-d/version.env
export EKS_DX_CONTROL_PLANE_VERSION INSTALL_EKS_DX

# Pre-install EKS-D binaries (kubeadm, kubelet, kubectl) to avoid downloading at boot
echo "==> Pre-installing EKS-D binaries..."
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && ARCH="arm64"
[ "$ARCH" = "x86_64" ] && ARCH="amd64"
RELEASE_MANIFEST="/opt/eks-d/manifests/eks-d-release.yaml"
KUBEADM_URL=$(grep "bin/linux/${ARCH}/kubeadm" "$RELEASE_MANIFEST" -B 1 | grep "uri:" | awk '{print $2}')
KUBELET_URL=$(grep "bin/linux/${ARCH}/kubelet" "$RELEASE_MANIFEST" -B 1 | grep "uri:" | awk '{print $2}')
KUBECTL_URL=$(grep "bin/linux/${ARCH}/kubectl" "$RELEASE_MANIFEST" -B 1 | grep "uri:" | awk '{print $2}')
curl -sL "$KUBEADM_URL" -o /tmp/kubeadm
curl -sL "$KUBELET_URL" -o /tmp/kubelet
curl -sL "$KUBECTL_URL" -o /tmp/kubectl
sudo install -o root -g root -m 0755 /tmp/kubeadm /usr/local/bin/kubeadm
sudo install -o root -g root -m 0755 /tmp/kubelet /usr/local/bin/kubelet
sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm -f /tmp/kubeadm /tmp/kubelet /tmp/kubectl
echo "✓ EKS-D binaries installed (kubeadm, kubelet, kubectl)"

echo "==> Installing ecr-credential-provider..."
sudo install -o root -g root -m 0755 /tmp/ecr-credential-provider /usr/bin/ecr-credential-provider
rm -f /tmp/ecr-credential-provider
echo "✓ ecr-credential-provider installed"

echo "==> Installing eks-dx CLI..."
if [[ "${INSTALL_EKS_DX:-false}" == "true" ]]; then
  EKS_DX_CLI_URL="https://github.com/plasticity-of-cloud/eks-d-xpress-control-plane/releases/download/v${EKS_DX_CONTROL_PLANE_VERSION}/eks-dx-cli-${EKS_DX_CONTROL_PLANE_VERSION}-linux-${ARCH}"
  curl -fsSL "$EKS_DX_CLI_URL" -o /tmp/eks-dx
  sudo install -o root -g root -m 0755 /tmp/eks-dx /usr/local/bin/eks-dx
  rm -f /tmp/eks-dx
  echo "✓ eks-dx CLI installed"
else
  echo "  Skipping eks-dx CLI (INSTALL_EKS_DX=false)"
fi

echo "==> Installing syft (SBOM generator)..."
SYFT_URL="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_${ARCH}.tar.gz"
curl -sL "$SYFT_URL" -o /tmp/syft.tar.gz
tar -xzf /tmp/syft.tar.gz -C /tmp syft
sudo install -o root -g root -m 0755 /tmp/syft /usr/local/bin/syft
rm -f /tmp/syft.tar.gz /tmp/syft
echo "✓ syft ${SYFT_VERSION} installed"

export AMI_BUILD=true

# Set up ECR pull-through cache — resolve account/region early but auth after containerd is installed
echo "==> Resolving ECR pull-through cache endpoint..."

# Wait for IAM instance profile credentials to be available via IMDS
ACCOUNT_ID=""
REGION=""
set +e
for i in $(seq 1 12); do
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1)
  echo "${ACCOUNT_ID}" | grep -qE '^[0-9]{12}$' && break
  sleep 5
done
set -e
if ! echo "${ACCOUNT_ID}" | grep -qE '^[0-9]{12}$'; then
  echo "ERROR: Could not obtain IAM credentials after 60s" >&2; exit 1
fi
REGION=$(aws sts get-caller-identity --query 'Arn' --output text | cut -d: -f4)
# Fall back to IMDSv2 if region not in ARN
if [ -z "${REGION}" ] || [ "${REGION}" = "None" ]; then
  TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  REGION=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/region)
fi
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
PUBLIC_ECR_CACHE="${ECR_REGISTRY}/public-ecr"
K8S_REGISTRY_CACHE="${ECR_REGISTRY}/registry-k8s-io"
echo "    ✓ ECR registry: ${ECR_REGISTRY}"

echo "==> Baking kubelet systemd service..."
sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/kubelet.service
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
cat <<'EOF' | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF
sudo systemctl daemon-reload
sudo systemctl enable kubelet
echo "✓ kubelet service baked and enabled"

echo "==> Baking ECR credential provider config..."
sudo mkdir -p /etc/kubernetes/credential-provider
cat <<'EOF' | sudo tee /etc/kubernetes/credential-provider/config.yaml
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
EOF
echo "✓ ECR credential provider config baked"

echo "==> Baking Kubernetes kernel networking settings..."
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
nf_conntrack
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe nf_conntrack
cat <<'EOF' | sudo tee /etc/sysctl.d/99-k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

echo "==> Preventing systemd-networkd from managing ENI secondary IPs..."
# VPC CNI assigns secondary IPs to ENIs for pod networking via veth pairs.
# Without this, systemd-networkd's DHCPv4 adds those IPs directly to the host
# interface, causing routing conflicts that hang CNI at startup.
sudo mkdir -p /etc/systemd/network/70-ens5.network.d
cat <<'EOF' | sudo tee /etc/systemd/network/70-ens5.network.d/no-secondary-ips.conf
[DHCPv4]
UseAddress=no
EOF
echo "✓ systemd-networkd drop-in written (ENI secondary IPs won't be claimed by host)"

echo "==> Installing base system..."
bash "${SCRIPT_DIR}/01-install-base.sh"

echo "==> Installing Docker..."
bash "${SCRIPT_DIR}/02-install-docker.sh"

echo "==> Installing Helm..."
bash "${SCRIPT_DIR}/04-install-helm.sh"

# Configure containerd with EKS-D pause image (release manifest already downloaded by 06)
echo "==> Configuring containerd..."
bash "${SCRIPT_DIR}/00-configure-containerd.sh"

# Authenticate with ECR now that containerd and helm are installed
echo "==> Authenticating with ECR pull-through cache..."
ECR_PASSWORD=$(aws ecr get-login-password --region "${REGION}")

# ctr needs explicit --user for authenticated pulls
ECR_CTR_USER="AWS:${ECR_PASSWORD}"

# Authenticate helm with ECR
echo "${ECR_PASSWORD}" | helm registry login --username AWS --password-stdin "${ECR_REGISTRY}"

# Copy eks-d-setup scripts to AMI for use at boot time
echo "==> Installing eks-d-setup scripts..."
sudo mkdir -p /opt/eks-d-setup
sudo cp -r "${EKS_D_SETUP_DIR}"/* /opt/eks-d-setup/
sudo chmod +x /opt/eks-d-setup/*.sh

# Pre-download Helm charts and manifests FIRST (needed for image discovery)
echo "==> Pre-pulling cert-manager chart..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm pull jetstack/cert-manager --version "v1.17.1" --destination /tmp || true
sudo mv /tmp/cert-manager-*.tgz /opt/eks-d-setup/charts/ 2>/dev/null || true

echo "==> Pre-pulling EKS-DX Pod Identity charts..."
if [[ "${INSTALL_EKS_DX:-false}" == "true" ]]; then
  helm pull oci://ghcr.io/plasticity-of-cloud/helm/eks-dx-pod-identity-webhook --version "${EKS_DX_CONTROL_PLANE_VERSION}" --destination /tmp || true
  helm pull oci://ghcr.io/plasticity-of-cloud/helm/eks-dx-auth-proxy --version "${EKS_DX_CONTROL_PLANE_VERSION}" --destination /tmp || true
else
  echo "  Skipping EKS-DX charts (INSTALL_EKS_DX=false)"
fi

echo "==> Pre-pulling eks-pod-identity-agent chart..."
git clone --depth=1 https://github.com/aws/eks-pod-identity-agent.git /tmp/eks-pod-identity-agent-repo || true
if [ -d /tmp/eks-pod-identity-agent-repo/charts/eks-pod-identity-agent ]; then
  helm package /tmp/eks-pod-identity-agent-repo/charts/eks-pod-identity-agent --destination /tmp || true
fi
rm -rf /tmp/eks-pod-identity-agent-repo

echo "==> Pre-pulling Karpenter chart from OCI registry..."
helm registry logout public.ecr.aws 2>/dev/null || true
helm pull oci://public.ecr.aws/karpenter/karpenter --version "1.10.0" --destination /tmp || true
helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update
helm pull aws-cloud-controller-manager/aws-cloud-controller-manager --destination /tmp || true
helm pull aws-ebs-csi-driver/aws-ebs-csi-driver --destination /tmp || true
sudo mkdir -p /opt/eks-d-setup/charts
sudo mv /tmp/karpenter-*.tgz /opt/eks-d-setup/charts/ 2>/dev/null || true
sudo mv /tmp/aws-cloud-controller-manager-*.tgz /opt/eks-d-setup/charts/ 2>/dev/null || true
sudo mv /tmp/aws-ebs-csi-driver-*.tgz /opt/eks-d-setup/charts/ 2>/dev/null || true
sudo mv /tmp/eks-dx-auth-proxy-*.tgz /opt/eks-d-setup/charts/ 2>/dev/null || true
sudo mv /tmp/eks-dx-pod-identity-webhook-*.tgz /opt/eks-d-setup/charts/ 2>/dev/null || true
sudo mv /tmp/eks-pod-identity-agent-*.tgz /opt/eks-d-setup/charts/ 2>/dev/null || true

echo "==> Pre-pulling CloudWatch Observability Helm chart..."
helm repo add aws-observability https://aws-observability.github.io/helm-charts 2>/dev/null || true
helm repo update
helm pull aws-observability/amazon-cloudwatch-observability --destination /tmp || true
sudo mv /tmp/amazon-cloudwatch-observability-*.tgz /opt/eks-d-setup/charts/ 2>/dev/null || true

echo "==> Pre-downloading manifests..."
sudo mkdir -p /opt/eks-d/manifests
sudo curl -sL "https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.20.4/config/master/aws-k8s-cni.yaml" \
  -o /opt/eks-d/manifests/aws-vpc-cni.yaml

# Tune IPAMD warm pool for single-node workstation: reduces cold-start from ~30s to ~2s.
# WARM_ENI_TARGET=0 — don't pre-allocate a full spare ENI
# WARM_IP_TARGET=1  — keep only 1 spare IP ready
# MINIMUM_IP_TARGET=1 — floor of 1 IP; IPAMD declares healthy as soon as this is met
python3 - /opt/eks-d/manifests/aws-vpc-cni.yaml <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
content = re.sub(r'(- name: WARM_ENI_TARGET\s*\n\s*value:) "1"', r'\1 "0"', content)
content = re.sub(
    r'(- name: WARM_ENI_TARGET\n\s+value: "0")',
    '- name: WARM_IP_TARGET\n              value: "1"\n            - name: MINIMUM_IP_TARGET\n              value: "1"\n            \\1',
    content
)
open(sys.argv[1], 'w').write(content)
PYEOF
sudo chown root:root /opt/eks-d/manifests/aws-vpc-cni.yaml
echo "✓ VPC CNI manifest patched (WARM_IP_TARGET=1, MINIMUM_IP_TARGET=1, WARM_ENI_TARGET=0)"

# Note: CoreDNS is installed automatically by kubeadm init — no separate manifest needed

# Pre-bake CNI binaries from the VPC CNI init container image so the init
# container finds them on first boot and skips extraction (~20s saving).
echo "==> Pre-baking CNI binaries from aws-k8s-cni-init..."
CNI_INIT_IMG=$(grep "image:" /opt/eks-d/manifests/aws-vpc-cni.yaml | grep "cni-init" | head -1 | awk '{print $2}')
if [ -n "$CNI_INIT_IMG" ]; then
  sudo mkdir -p /opt/cni/bin
  docker create --name cni-prebake "$CNI_INIT_IMG" 2>/dev/null && \
    sudo docker cp cni-prebake:/opt/cni/bin/. /opt/cni/bin/ && \
    docker rm cni-prebake || docker rm -f cni-prebake 2>/dev/null || true
  echo "✓ CNI binaries baked to /opt/cni/bin ($(ls /opt/cni/bin | wc -l) files)"
else
  echo "Warning: could not determine CNI init image — /opt/cni/bin not pre-baked"
fi

# Pre-pull container images by inspecting charts and manifests
echo "==> Discovering and pre-pulling container images..."
sudo systemctl start containerd

# Pull EKS-D control plane images directly from the downloaded manifest
echo "==> Pulling EKS-D control plane images..."
grep "uri: public.ecr.aws/eks-distro/kubernetes/" /opt/eks-d/manifests/eks-d-release.yaml | awk '{print $2}' | sort -u | while read img; do
  cache_img="${PUBLIC_ECR_CACHE}/${img#public.ecr.aws/}"
  echo "  Pulling: $cache_img"
  sudo ctr -n k8s.io images pull --user "${ECR_CTR_USER}" "$cache_img" || true
done
grep "uri: public.ecr.aws/eks-distro/etcd-io/" /opt/eks-d/manifests/eks-d-release.yaml | awk '{print $2}' | sort -u | while read img; do
  cache_img="${PUBLIC_ECR_CACHE}/${img#public.ecr.aws/}"
  echo "  Pulling: $cache_img"
  sudo ctr -n k8s.io images pull --user "${ECR_CTR_USER}" "$cache_img" || true
done
grep "uri: public.ecr.aws/eks-distro/coredns/" /opt/eks-d/manifests/eks-d-release.yaml | awk '{print $2}' | sort -u | while read img; do
  cache_img="${PUBLIC_ECR_CACHE}/${img#public.ecr.aws/}"
  echo "  Pulling: $cache_img"
  sudo ctr -n k8s.io images pull --user "${ECR_CTR_USER}" "$cache_img" || true
done

# Render Karpenter chart and extract images
# Pull directly from public.ecr.aws — pull-through cache path for karpenter doesn't exist
echo "==> Extracting and pulling images from Karpenter chart..."
KARPENTER_CHART=$(ls /opt/eks-d-setup/charts/karpenter-*.tgz 2>/dev/null | head -1)
if [ -n "$KARPENTER_CHART" ]; then
  helm template karpenter "$KARPENTER_CHART" 2>/dev/null | \
    grep -oP '(?:image|value):\s*\K[^\s"]+' | grep 'public\.ecr\.aws' | sort -u | while read img; do
      echo "  Pulling: $img"
      sudo ctr -n k8s.io images pull "$img" || true
    done
fi

# Render cloud-provider-aws chart and extract images
# registry.k8s.io images routed through ECR pull-through cache (registry-k8s-io prefix)
echo "==> Extracting and pulling images from cloud-provider-aws chart..."
CLOUD_PROVIDER_CHART=$(ls /opt/eks-d-setup/charts/aws-cloud-controller-manager-*.tgz 2>/dev/null | head -1)
if [ -n "$CLOUD_PROVIDER_CHART" ]; then
  cat > /tmp/extract_images.py << 'PYEOF'
import sys, re
for line in sys.stdin:
    m = re.search(r"image:\s*[\"']?([a-zA-Z0-9._/-]+:[a-zA-Z0-9._/-]+)[\"']?", line)
    if m:
        print(m.group(1))
PYEOF
  helm template aws-cloud-controller-manager "$CLOUD_PROVIDER_CHART" 2>/dev/null | \
    python3 /tmp/extract_images.py | sort -u | while read img; do
      cache_img=$(echo "$img" | sed \
        -e "s|public.ecr.aws/|${PUBLIC_ECR_CACHE}/|" \
        -e "s|registry.k8s.io/|${K8S_REGISTRY_CACHE}/|")
      echo "  Pulling: $cache_img"
      sudo ctr -n k8s.io images pull --user "${ECR_CTR_USER}" "$cache_img" || true
    done
fi

# Render EBS CSI chart and extract images
echo "==> Extracting and pulling images from EBS CSI chart..."
EBS_CSI_CHART=$(ls /opt/eks-d-setup/charts/aws-ebs-csi-driver-*.tgz 2>/dev/null | head -1)
if [ -n "$EBS_CSI_CHART" ]; then
  helm template aws-ebs-csi-driver "$EBS_CSI_CHART" 2>/dev/null | \
    grep -oP 'image:\s*\K[^\s]+' | grep -Ev 'windows|nvidia|neuron|dcgm-exporter|kubekins-e2e|e2e-test' | sort -u | while read img; do
      cache_img=$(echo "$img" | sed "s|public.ecr.aws/|${PUBLIC_ECR_CACHE}/|")
      echo "  Pulling: $cache_img"
      sudo ctr -n k8s.io images pull --user "${ECR_CTR_USER}" "$cache_img" || true
    done
fi

# Extract images from VPC CNI manifest
# Images are in 602401143452.dkr.ecr.us-west-2 — requires explicit ECR auth for that region
echo "==> Extracting and pulling images from VPC CNI manifest..."
if [ -f /opt/eks-d/manifests/aws-vpc-cni.yaml ]; then
  VPC_CNI_ECR_TOKEN=$(aws ecr get-login-password --region us-west-2)
  grep -oP 'image:\s*\K[^\s]+' /opt/eks-d/manifests/aws-vpc-cni.yaml | sort -u | while read img; do
    echo "  Pulling: $img"
    sudo ctr -n k8s.io images pull --user "AWS:${VPC_CNI_ECR_TOKEN}" "$img" || true
  done
fi

# EBS CSI driver images are extracted and pulled from the chart above

# Pull CSI sidecar images using discovered versions
if [ -n "$CSI_PROVISIONER_IMAGE" ]; then
  sudo ctr -n k8s.io images pull "$CSI_PROVISIONER_IMAGE" || true
fi
if [ -n "$CSI_ATTACHER_IMAGE" ]; then
  sudo ctr -n k8s.io images pull "$CSI_ATTACHER_IMAGE" || true
fi
if [ -n "$LIVENESSPROBE_IMAGE" ]; then
  sudo ctr -n k8s.io images pull "$LIVENESSPROBE_IMAGE" || true
fi
if [ -n "$CSI_RESIZER_IMAGE" ]; then
  sudo ctr -n k8s.io images pull "$CSI_RESIZER_IMAGE" || true
fi

# Metrics Server
if [ -n "$METRICS_SERVER_IMAGE" ]; then
  echo "==> Pulling Metrics Server image..."
  sudo ctr -n k8s.io images pull "$METRICS_SERVER_IMAGE" || true
fi

# aws-iam-authenticator — runs as static pod for worker node IAM auth
echo "==> Pulling aws-iam-authenticator image..."
if [ -n "$AWS_IAM_AUTHENTICATOR_IMAGE" ]; then
  sudo ctr -n k8s.io images pull "$AWS_IAM_AUTHENTICATOR_IMAGE" || true
fi

# Render CloudWatch Observability chart and extract images
echo "==> Extracting and pulling images from CloudWatch Observability chart..."
CW_CHART=$(ls /opt/eks-d-setup/charts/amazon-cloudwatch-observability-*.tgz 2>/dev/null | head -1)
if [ -n "$CW_CHART" ]; then
  cat > /tmp/extract_images_cw.py << 'PYEOF'
import sys, re
SKIP = re.compile(r'windows|nvidia|neuron|dcgm-exporter|kubekins-e2e')
for line in sys.stdin:
    m = re.search(r"image:\s*[\"']?([a-zA-Z0-9._/-]+:[a-zA-Z0-9._/-]+)[\"']?", line)
    if m and not SKIP.search(m.group(1)):
        print(m.group(1))
PYEOF
  helm template amazon-cloudwatch-observability "$CW_CHART" \
    --set clusterName=build --set region=us-east-1 2>/dev/null | \
    python3 /tmp/extract_images_cw.py | sort -u | while read img; do
      cache_img=$(echo "$img" | sed "s|public.ecr.aws/|${PUBLIC_ECR_CACHE}/|")
      echo "  Pulling: $cache_img"
      sudo ctr -n k8s.io images pull --user "${ECR_CTR_USER}" "$cache_img" || true
    done
fi

# Render cert-manager chart and extract images (quay.io — pulled through ECR pull-through cache)
echo "==> Extracting and pulling images from cert-manager chart..."
CERT_MANAGER_CHART=$(ls /opt/eks-d-setup/charts/cert-manager-*.tgz 2>/dev/null | head -1)
QUAY_CACHE="${ECR_REGISTRY}/quay-io"
if [ -n "$CERT_MANAGER_CHART" ]; then
  helm template cert-manager "$CERT_MANAGER_CHART" --set crds.enabled=true 2>/dev/null | \
    grep -oP 'image:\s*\K[^\s]+' | grep 'quay\.io' | sort -u | while read img; do
      cache_img=$(echo "$img" | sed "s|quay.io/|${QUAY_CACHE}/|")
      echo "  Pulling: $cache_img"
      sudo ctr -n k8s.io images pull --user "${ECR_CTR_USER}" "$cache_img" || true
    done
fi

# Pre-pull EKS-DX Pod Identity images
echo "==> Pulling EKS-DX Pod Identity images..."
if [[ "${INSTALL_EKS_DX:-false}" == "true" ]]; then
  sudo ctr -n k8s.io images pull ghcr.io/plasticity-of-cloud/eks-dx-auth-proxy:${EKS_DX_CONTROL_PLANE_VERSION} || true
  sudo ctr -n k8s.io images pull ghcr.io/plasticity-of-cloud/eks-dx-pod-identity-webhook:${EKS_DX_CONTROL_PLANE_VERSION} || true
  sudo ctr -n k8s.io images pull 602401143452.dkr.ecr.us-west-2.amazonaws.com/eks/eks-pod-identity-agent:latest || true
else
  echo "  Skipping EKS-DX images (INSTALL_EKS_DX=false)"
fi

# Install eks-dx-boot systemd service (starts cluster bootstrap at multi-user.target)
echo "==> Installing eks-dx-boot.service..."
sudo cp /tmp/scripts/eks-dx-boot.service /etc/systemd/system/eks-dx-boot.service
sudo systemctl daemon-reload
sudo systemctl enable eks-dx-boot.service

# Disable swap — kubeadm requires swap off; persists across reboots.
echo "==> Disabling swap..."
sudo swapoff -a
sudo touch /etc/systemd/zram-generator.conf  # empty file disables zram swap
sudo sed -i '/ swap /d' /etc/fstab 2>/dev/null || true

# Clean up helm ECR session — workstations use the ECR credential provider instead
echo "==> Cleaning up temporary ECR credentials..."
helm registry logout "${ECR_REGISTRY}" 2>/dev/null || true

echo ""
echo "==> AMI build complete!"
echo "    Scripts installed to /opt/eks-d-setup/"
echo "    Charts installed to /opt/eks-d-setup/charts/"
echo "    Manifests installed to /opt/eks-d/manifests/"
echo "    All images pre-pulled for fast boot."
