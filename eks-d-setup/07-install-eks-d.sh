#!/bin/bash
# 07-install-eks-d.sh - kubeadm init only.
# All binaries (kubeadm, kubelet, kubectl), kubelet systemd service, sysctl,
# kernel modules, containerd, and ECR credential provider are pre-baked into the AMI.
set -e

RELEASE_MANIFEST="/opt/eks-d/manifests/eks-d-release.yaml"

if [ ! -f "$RELEASE_MANIFEST" ]; then
  echo "Error: $RELEASE_MANIFEST not found — was this AMI built correctly?"
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ]  && ARCH="amd64"
[ "$ARCH" = "aarch64" ] && ARCH="arm64"

# Extract image tags from the baked release manifest
EKSD_K8S_TAG=$(grep "kubernetes/kube-apiserver" "$RELEASE_MANIFEST" | grep "uri:" | head -1 | sed 's/.*://')
EKSD_ETCD_TAG=$(grep "etcd-io/etcd" "$RELEASE_MANIFEST" | grep "uri:" | head -1 | sed 's/.*://')
EKSD_COREDNS_TAG=$(grep "coredns/coredns" "$RELEASE_MANIFEST" | grep "uri:" | head -1 | sed 's/.*://')

# All runtime values come from cluster.env (written by TenantEc2Service at launch)
source /opt/eks-d/cluster.env

if [ -z "${NODE_IP:-}" ] || [ -z "${POD_SUBNET:-}" ]; then
  echo "Error: NODE_IP and POD_SUBNET must be set in /opt/eks-d/cluster.env"
  exit 1
fi

echo "  k8s tag:    ${EKSD_K8S_TAG}"
echo "  etcd tag:   ${EKSD_ETCD_TAG}"
echo "  coredns tag:${EKSD_COREDNS_TAG}"
echo "  node IP:    ${NODE_IP}"
echo "  pod subnet: ${POD_SUBNET}"

cat <<EOF | sudo tee /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
imageRepository: public.ecr.aws/eks-distro/kubernetes
kubernetesVersion: ${EKSD_K8S_TAG}
controlPlaneEndpoint: ${NODE_IP}
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: "${POD_SUBNET}"
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
    node-ip: "${NODE_IP}"
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
  if sudo kubectl get nodes --kubeconfig /etc/kubernetes/admin.conf >/dev/null 2>&1; then
    echo "✓ Cluster is functional despite kubeadm warnings"
  else
    echo "✗ Cluster initialization failed"
    exit 1
  fi
}

mkdir -p $HOME/.kube /root/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
cp /etc/kubernetes/admin.conf /root/.kube/config

rm -f /tmp/kubeadm-config.yaml

echo "✓ EKS-D installed"
kubectl get nodes

# Auto-approve kubelet serving CSRs (serverTLSBootstrap: true requires this;
# kube-controller-manager only auto-approves client CSRs, not serving CSRs)
echo "Approving pending kubelet serving CSRs..."
for csr in $(kubectl get csr -o jsonpath='{.items[?(@.status.certificate=="")].metadata.name}'); do
  kubectl certificate approve "$csr" 2>/dev/null || true
done
echo "✓ Kubelet serving CSRs approved"

# Remove loop plugin from CoreDNS — false positive with VPC CNI SNAT on single-node
kubectl get cm coredns -n kube-system -o yaml | sed "/^[[:space:]]*loop$/d" | kubectl apply -f -
echo "✓ CoreDNS loop plugin removed"

# Wait for kube-proxy to program ClusterIP iptables rules before CNI install.
echo "Waiting for kube-proxy to program service routing rules..."
KUBE_SVC_IP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
for i in $(seq 1 15); do
  curl -sk --connect-timeout 2 "https://${KUBE_SVC_IP}:443/version" >/dev/null 2>&1 && {
    echo "✓ kube-proxy rules active (ClusterIP ${KUBE_SVC_IP} routable)"
    break
  }
  [ "$i" -eq 15 ] && echo "Warning: kube-proxy rules not confirmed after 15s, proceeding anyway"
  sleep 1
done
