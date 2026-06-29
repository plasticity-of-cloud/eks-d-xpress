#!/bin/bash
set -e

# EKS-D AMI Installation Script — orchestrator
# Pre-installs binaries, images, and scripts for fast workstation boot.
# Component-specific chart/image pulls live in scripts/components/*.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EKS_D_SETUP_DIR="/tmp/eks-d-setup"

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35}"
EKS_VERSION="${KUBERNETES_VERSION}"

# ── 1. Version discovery ──────────────────────────────────────────────────────
echo "==> Discovering EKS-D components for Kubernetes ${EKS_VERSION}..."
sudo mkdir -p /opt/eks-d
echo "EKS_VERSION=${EKS_VERSION}" | sudo tee /opt/eks-d/version.env

bash "${SCRIPT_DIR}/discover-eks-d.sh" "$EKS_VERSION" "/opt/eks-d/manifests"
source /opt/eks-d/manifests/eks-d-versions.env
echo "==> Using EKS-D ${EKSD_VERSION}-eks-${EKSD_RELEASE}"

EKSD_DOTTED="${EKS_VERSION}.${EKSD_RELEASE}"
echo "EKSD_VERSION=${EKSD_DOTTED}" | sudo tee -a /opt/eks-d/version.env

VERSIONS_ENV="${SCRIPT_DIR}/component-versions.env"
[ -f "$VERSIONS_ENV" ] && source "$VERSIONS_ENV"
: "${EKS_DX_CONTROL_PLANE_VERSION:?component-versions.env missing or EKS_DX_CONTROL_PLANE_VERSION not set}"
echo "EKS_DX_CONTROL_PLANE_VERSION=${EKS_DX_CONTROL_PLANE_VERSION}" | sudo tee -a /opt/eks-d/version.env
echo "INSTALL_EKS_DX=${INSTALL_EKS_DX:-false}" | sudo tee -a /opt/eks-d/version.env
echo "CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION}" | sudo tee -a /opt/eks-d/version.env
echo "KARPENTER_VERSION=${KARPENTER_VERSION}" | sudo tee -a /opt/eks-d/version.env
export EKS_DX_CONTROL_PLANE_VERSION INSTALL_EKS_DX

# ── 2. Binary installation ────────────────────────────────────────────────────
echo "==> Pre-installing EKS-D binaries (kubeadm, kubelet, kubectl)..."
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && ARCH="arm64"
[ "$ARCH" = "x86_64" ] && ARCH="amd64"
RELEASE_MANIFEST="/opt/eks-d/manifests/eks-d-release.yaml"
for bin in kubeadm kubelet kubectl; do
  URL=$(grep "bin/linux/${ARCH}/${bin}" "$RELEASE_MANIFEST" -B 1 | grep "uri:" | awk '{print $2}')
  curl -sL "$URL" -o "/tmp/${bin}"
  sudo install -o root -g root -m 0755 "/tmp/${bin}" "/usr/local/bin/${bin}"
  rm -f "/tmp/${bin}"
done
echo "✓ EKS-D binaries installed"

echo "==> Installing ecr-credential-provider..."
sudo install -o root -g root -m 0755 /tmp/ecr-credential-provider /usr/bin/ecr-credential-provider
rm -f /tmp/ecr-credential-provider

echo "==> Installing syft (${SYFT_VERSION})..."
curl -sL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_${ARCH}.tar.gz" \
  -o /tmp/syft.tar.gz
tar -xzf /tmp/syft.tar.gz -C /tmp syft
sudo install -o root -g root -m 0755 /tmp/syft /usr/local/bin/syft
rm -f /tmp/syft.tar.gz /tmp/syft

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

# ── 3. System configuration ───────────────────────────────────────────────────
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

echo "==> Baking Kubernetes kernel networking settings..."
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
nf_conntrack
EOF
sudo modprobe overlay br_netfilter nf_conntrack
cat <<'EOF' | sudo tee /etc/sysctl.d/99-k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

echo "==> Preventing systemd-networkd from managing ENI secondary IPs..."
sudo mkdir -p /etc/systemd/network/70-ens5.network.d
cat <<'EOF' | sudo tee /etc/systemd/network/70-ens5.network.d/no-secondary-ips.conf
[DHCPv4]
UseAddress=no
EOF

# ── 4. Tool installation ──────────────────────────────────────────────────────
echo "==> Installing base system..."
bash "${SCRIPT_DIR}/01-install-base.sh"
echo "==> Installing Docker..."
bash "${SCRIPT_DIR}/02-install-docker.sh"
echo "==> Installing Helm..."
bash "${SCRIPT_DIR}/04-install-helm.sh"
echo "==> Configuring containerd..."
bash "${SCRIPT_DIR}/00-configure-containerd.sh"

# ── 5. ECR authentication → shared env file for component scripts ─────────────
echo "==> Resolving ECR credentials..."
ACCOUNT_ID=""
set +e
for i in $(seq 1 12); do
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1)
  echo "${ACCOUNT_ID}" | grep -qE '^[0-9]{12}$' && break
  sleep 5
done
set -e
echo "${ACCOUNT_ID}" | grep -qE '^[0-9]{12}$' || \
  { echo "ERROR: Could not obtain IAM credentials after 60s" >&2; exit 1; }

REGION=$(aws sts get-caller-identity --query 'Arn' --output text | cut -d: -f4)
if [ -z "${REGION}" ] || [ "${REGION}" = "None" ]; then
  TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  REGION=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/region)
fi

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ECR_PASSWORD=$(aws ecr get-login-password --region "${REGION}")
echo "${ECR_PASSWORD}" | helm registry login --username AWS --password-stdin "${ECR_REGISTRY}"

# Registry routing: release builds use upstream directly; internal builds use pull-through cache.
# Component scripts reference only the variables below — no build-type logic in those scripts.
BUILD_TYPE="${BUILD_TYPE:-internal}"
if [[ "${BUILD_TYPE}" == "release" ]]; then
  PUBLIC_ECR_CACHE="public.ecr.aws"
  K8S_REGISTRY_CACHE="registry.k8s.io"
  QUAY_CACHE="quay.io"
  echo "    Build type: release (direct upstream registries)"
else
  PUBLIC_ECR_CACHE="${ECR_REGISTRY}/public-ecr"
  K8S_REGISTRY_CACHE="${ECR_REGISTRY}/registry-k8s-io"
  QUAY_CACHE="${ECR_REGISTRY}/quay-io"
  echo "    Build type: internal (pull-through cache: ${ECR_REGISTRY})"
fi

# Write shared state for component scripts
cat > /tmp/ami-build.env <<EOF
BUILD_TYPE=${BUILD_TYPE}
ECR_REGISTRY=${ECR_REGISTRY}
PUBLIC_ECR_CACHE=${PUBLIC_ECR_CACHE}
K8S_REGISTRY_CACHE=${K8S_REGISTRY_CACHE}
QUAY_CACHE=${QUAY_CACHE}
ECR_CTR_USER=AWS:${ECR_PASSWORD}
REGION=${REGION}
ACCOUNT_ID=${ACCOUNT_ID}
INSTALL_EKS_DX=${INSTALL_EKS_DX:-false}
EKS_DX_CONTROL_PLANE_VERSION=${EKS_DX_CONTROL_PLANE_VERSION}
GHCR_EKS_D_XPRESS_REGISTRY=${GHCR_EKS_D_XPRESS_REGISTRY:-ghcr.io/plasticity-of-cloud}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION}
KARPENTER_VERSION=${KARPENTER_VERSION}
METRICS_SERVER_IMAGE=${METRICS_SERVER_IMAGE:-}
AWS_IAM_AUTHENTICATOR_IMAGE=${AWS_IAM_AUTHENTICATOR_IMAGE:-}
EXTRACT_IMAGES_PY=${SCRIPT_DIR}/extract-images.py
EOF

# ── 6. Stage files ────────────────────────────────────────────────────────────
echo "==> Staging eks-d-setup scripts..."
sudo mkdir -p /opt/eks-d-setup/charts
sudo cp -r "${EKS_D_SETUP_DIR}"/* /opt/eks-d-setup/
sudo chmod +x /opt/eks-d-setup/*.sh

echo "==> Staging Karpenter node-pools..."
sudo mkdir -p /opt/eks-d-setup/karpenter
sudo cp -r /tmp/node-pools/chart /opt/eks-d-setup/karpenter/
sudo cp /tmp/node-pools/configure-nodepools.sh /opt/eks-d-setup/karpenter/
sudo chmod +x /opt/eks-d-setup/karpenter/configure-nodepools.sh

# ── 7. Component scripts ──────────────────────────────────────────────────────
export AMI_BUILD=true
sudo systemctl start containerd

COMPONENTS_DIR="${SCRIPT_DIR}/components"
for component in \
    cert-manager \
    karpenter \
    ebs-csi \
    cloud-provider-aws \
    vpc-cni \
    cloudwatch \
    system-images \
    eks-dx; do
  echo "==> Component: ${component}"
  bash "${COMPONENTS_DIR}/${component}.sh"
done

# ── 8. EKS-D control plane images (from release manifest) ────────────────────
echo "==> Pulling EKS-D control plane images from release manifest..."
source /tmp/ami-build.env
for prefix in kubernetes etcd-io coredns; do
  grep "uri: public.ecr.aws/eks-distro/${prefix}/" \
    /opt/eks-d/manifests/eks-d-release.yaml | awk '{print $2}' | sort -u | while read img; do
      sudo ctr -n k8s.io images pull \
        --user "${ECR_CTR_USER}" \
        "$(echo "$img" | sed "s|public.ecr.aws/|${PUBLIC_ECR_CACHE}/|")" || true
    done
done

# ── 9. Final setup ────────────────────────────────────────────────────────────
echo "==> Installing eks-dx-boot.service..."
sudo cp /tmp/scripts/eks-dx-boot.service /etc/systemd/system/eks-dx-boot.service
sudo systemctl daemon-reload
sudo systemctl enable eks-dx-boot.service

echo "==> Disabling swap..."
sudo swapoff -a
sudo touch /etc/systemd/zram-generator.conf
sudo sed -i '/ swap /d' /etc/fstab 2>/dev/null || true

echo "==> Cleaning up ECR credentials..."
helm registry logout "${ECR_REGISTRY}" 2>/dev/null || true
rm -f /tmp/ami-build.env

echo "==> Unpacking images into snapshotter..."
sudo ctr -n k8s.io images list -q | while read img; do
  sudo ctr -n k8s.io run --rm "$img" "warmup-$(echo "$img" | md5sum | cut -c1-8)" true 2>/dev/null || true
done

echo ""
echo "==> AMI build complete!"
echo "    Scripts:   /opt/eks-d-setup/"
echo "    Charts:    /opt/eks-d-setup/charts/"
echo "    Manifests: /opt/eks-d/manifests/"
