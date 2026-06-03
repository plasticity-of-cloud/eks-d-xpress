# Corrected Installation Order

## Current Order (Broken)

```
01  install-base.sh           — dnf update only
02  install-docker.sh         — Docker (not used by Kubernetes)
03  install-kubectl.sh
04  install-helm.sh
05  prepare-etcd.sh
06  install-eks-d.sh          — kubeadm init with wrong flags, upstream images
07  install-cni.sh            — AWS VPC CNI
    [07.5 MISSING]            — Cloud provider never installed
08  install-coredns.sh        — Broken template manifest, conflicts with kubeadm
09  install-ebs-csi.sh
10  configure-node.sh         — Untaint control plane
11  install-karpenter.sh
```

## Corrected Order

```
00  configure-containerd.sh   — NEW: EKS-D pause image + SystemdCgroup=true
01  install-base.sh
02  install-docker.sh
03  install-kubectl.sh
04  install-helm.sh
05  prepare-etcd.sh
06  install-eks-d.sh          — FIXED: kubeadm config file, EKS-D images, no pod-network-cidr
07  install-cni.sh            — AWS VPC CNI (unchanged)
07.5 install-cloud-provider.sh — ADDED: AWS Cloud Controller Manager
    [08 DELETED]              — CoreDNS handled by kubeadm
09  install-ebs-csi.sh
10  configure-node.sh         — Untaint control plane
11  install-karpenter.sh
```

---

## Changes Required Per File

### New: `00-configure-containerd.sh`
- Generate `/etc/containerd/config.toml` with `containerd config default`
- Set `sandbox_image` to EKS-D pause image from release manifest
- Set `SystemdCgroup = true`
- Restart containerd

See [05-containerd.md](05-containerd.md).

### Modified: `06-install-eks-d.sh`
- Replace `kubeadm init` CLI flags with a kubeadm config file
- Remove `--pod-network-cidr`
- Add `cloud-provider: external` to apiServer, controllerManager, and nodeRegistration
- Set EKS-D image repositories for k8s components, etcd, and CoreDNS
- Remove the `/etc/default/kubelet` override block at the end (replaced by kubeadm config)

See [01-kubeadm-init.md](01-kubeadm-init.md).

### Modified: `07.5-install-cloud-provider.sh`
- Set `hostNetwork=true` at Helm install time instead of patching after
- Remove the `kubectl patch` line
- Add tolerations for control-plane taint at install time

See [04-cloud-provider.md](04-cloud-provider.md).

### Deleted: `08-install-coredns.sh`
- kubeadm installs CoreDNS automatically
- The script uses broken template manifests
- Remove from `install-all.sh`

See [03-coredns.md](03-coredns.md).

### Modified: `install-all.sh`
- Add call to `00-configure-containerd.sh` before step 1
- Add call to `07.5-install-cloud-provider.sh` after step 7
- Remove call to `08-install-coredns.sh`
- Renumber steps accordingly

### Modified: `terraform/main.tf`
- Add `http_put_response_hop_limit = 2` to `metadata_options`
- Add security group ingress rules for port 6443, 10250, and self-referencing all-traffic

See [06-infrastructure.md](06-infrastructure.md).

---

## Post-Install Verification Sequence

Run these checks in order after installation. Each check depends on the previous one passing.

```bash
# 1. containerd using correct pause image
sudo grep sandbox_image /etc/containerd/config.toml | grep eks-distro

# 2. Control plane pods using EKS-D images
kubectl get pod -n kube-system kube-apiserver-$(hostname) \
  -o jsonpath='{.spec.containers[0].image}' | grep eks-distro

# 3. kube-controller-manager has cloud-provider=external
kubectl get pod -n kube-system kube-controller-manager-$(hostname) \
  -o jsonpath='{.spec.containers[0].command}' | grep 'cloud-provider=external'

# 4. aws-node running (CNI working)
kubectl get pods -n kube-system -l k8s-app=aws-node
# Expected: Running

# 5. Cloud controller manager running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cloud-controller-manager
# Expected: Running

# 6. Node has ProviderID
kubectl get node $(hostname) -o jsonpath='{.spec.providerID}'
# Expected: aws:///us-east-1x/i-0...

# 7. Node is Ready
kubectl get nodes
# Expected: Ready

# 8. CoreDNS running (kubeadm-installed)
kubectl get pods -n kube-system -l k8s-app=kube-dns
# Expected: Running (2/2)

# 9. Pod IPs are VPC IPs (not overlay)
kubectl get pods -A -o wide | awk '{print $7}' | grep -v IP | grep -v '<none>'
# Expected: all IPs in VPC CIDR (e.g., 10.0.x.x)

# 10. DNS resolution works
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm -it \
  -- nslookup kubernetes.default.svc.cluster.local
# Expected: resolves to 10.96.0.1
```
