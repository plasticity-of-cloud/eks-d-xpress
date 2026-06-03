# kubeadm Init Configuration for EKS-D

## Problem

`06-install-eks-d.sh` runs `kubeadm init` with bare CLI flags:

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --apiserver-advertise-address=${PRIVATE_IP} \
  --ignore-preflight-errors=NumCPU,DirAvailable--var-lib-etcd
```

This has three distinct bugs.

---

### Bug 1: Upstream images instead of EKS-D images

Without `--image-repository` or a config file, kubeadm pulls from `registry.k8s.io`:

- `registry.k8s.io/kube-apiserver:v1.33.x`
- `registry.k8s.io/kube-controller-manager:v1.33.x`
- `registry.k8s.io/etcd:3.5.x`
- `registry.k8s.io/coredns/coredns:v1.x.x`
- `registry.k8s.io/pause:3.x`

These are upstream Kubernetes images. EKS-D images are at:

- `public.ecr.aws/eks-distro/kubernetes/kube-apiserver:v1.33.x-eks-1-33-<release>`
- `public.ecr.aws/eks-distro/kubernetes/kube-controller-manager:v1.33.x-eks-1-33-<release>`
- `public.ecr.aws/eks-distro/etcd-io/etcd:v3.5.x-eks-1-33-<release>`
- `public.ecr.aws/eks-distro/coredns/coredns:v1.x.x-eks-1-33-<release>`
- `public.ecr.aws/eks-distro/kubernetes/pause:v1.33.x-eks-1-33-<release>`

Running EKS-D binaries against upstream images is not EKS-D — it is upstream Kubernetes with
EKS-D CLI tools. The EKS-D-specific patches and security fixes in the control plane images are
not applied.

---

### Bug 2: `cloud-provider: external` missing from control plane components

The script sets `--cloud-provider=external` in `/etc/default/kubelet` *after* `kubeadm init`:

```bash
echo "KUBELET_EXTRA_ARGS='--cloud-provider=external ...'" | sudo tee /etc/default/kubelet
sudo systemctl restart kubelet
```

This only affects the kubelet process. The kube-controller-manager and kube-apiserver are
written as static pod manifests to `/etc/kubernetes/manifests/` during `kubeadm init` and are
never updated. Without `--cloud-provider=external` on kube-controller-manager:

- The in-tree AWS cloud provider code path is taken (or errors out)
- Nodes never get their `spec.providerID` set correctly
- The AWS Cloud Controller Manager cannot take ownership of nodes
- Karpenter cannot identify EC2 instances by ProviderID

---

### Bug 3: `--pod-network-cidr` conflicts with AWS VPC CNI

`--pod-network-cidr=192.168.0.0/16` sets `--cluster-cidr=192.168.0.0/16` on
kube-controller-manager, which activates the node IPAM controller. This controller stamps
`spec.podCIDR = 192.168.0.0/24` on each node.

AWS VPC CNI does not use an overlay network. It assigns real VPC secondary IPs to pods directly
from the subnet ENI. It ignores `spec.podCIDR`. The conflicting IPAM controller causes routing
table entries for `192.168.0.0/24` to be added to the node, which interfere with VPC routing
and can prevent pods from getting IPs or communicating correctly.

---

## Verification of EKS-D Version String Acceptance

The EKS-D version string format (e.g., `v1.33.0-eks-1-33-19`) is valid semver with a
pre-release identifier and is accepted by kubeadm. This is confirmed by the
[official EKS-D kubeadm example](https://gist.github.com/thebsdbox/6401271aff6671fbd44255e32847455f)
which uses `--kubernetes-version v1.18.9-eks-1-18-1` directly.

---

## Fix

Replace the `kubeadm init` CLI call with a config file. The image tags must be extracted from
the EKS-D release manifest at runtime.

```bash
# Extract exact image tags from the EKS-D release manifest
EKSD_K8S_TAG=$(grep "tag:" /tmp/eks-d-release.yaml | grep "kube-apiserver" | head -1 | awk '{print $2}')
EKSD_ETCD_TAG=$(grep "tag:" /tmp/eks-d-release.yaml | grep "etcd" | head -1 | awk '{print $2}')
EKSD_COREDNS_TAG=$(grep "tag:" /tmp/eks-d-release.yaml | grep "coredns" | head -1 | awk '{print $2}')
PRIVATE_IP=$(hostname -I | awk '{print $1}')

cat <<EOF | sudo tee /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
imageRepository: public.ecr.aws/eks-distro/kubernetes
kubernetesVersion: ${EKSD_K8S_TAG}
controlPlaneEndpoint: ${PRIVATE_IP}
networking:
  serviceSubnet: 10.96.0.0/12
  # No podSubnet — AWS VPC CNI uses VPC IPs directly
apiServer:
  extraArgs:
    cloud-provider: external
controllerManager:
  extraArgs:
    cloud-provider: external
dns:
  imageRepository: public.ecr.aws/eks-distro/coredns
  imageTag: ${EKSD_COREDNS_TAG}
etcd:
  local:
    imageRepository: public.ecr.aws/eks-distro/etcd-io
    imageTag: ${EKSD_ETCD_TAG}
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs:
    cloud-provider: external
    image-credential-provider-config: /etc/kubernetes/credential-provider/config.yaml
    image-credential-provider-bin-dir: /usr/bin
EOF

sudo kubeadm init \
  --config /tmp/kubeadm-config.yaml \
  --ignore-preflight-errors=NumCPU,DirAvailable--var-lib-etcd
```

With this config:
- All control plane images come from `public.ecr.aws/eks-distro/`
- `cloud-provider: external` is set on kube-apiserver, kube-controller-manager, and kubelet
- No pod subnet CIDR is set — AWS VPC CNI manages pod IPs from the VPC
- The ECR credential provider is configured at init time, not patched in after

The `/etc/default/kubelet` override block at the end of `06-install-eks-d.sh` can be removed
since `nodeRegistration.kubeletExtraArgs` in the InitConfiguration replaces it.

---

## Verification

```bash
# Confirm EKS-D images are running (not registry.k8s.io)
kubectl get pod -n kube-system kube-apiserver-$(hostname) \
  -o jsonpath='{.spec.containers[0].image}'
# Expected: public.ecr.aws/eks-distro/kubernetes/kube-apiserver:v1.33.x-eks-1-33-...

# Confirm cloud-provider=external is set on kube-controller-manager
kubectl get pod -n kube-system kube-controller-manager-$(hostname) \
  -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep cloud-provider
# Expected: --cloud-provider=external

# Confirm no podCIDR conflict
kubectl get node $(hostname) -o jsonpath='{.spec.podCIDR}'
# Expected: empty (AWS VPC CNI manages IPs)
```
