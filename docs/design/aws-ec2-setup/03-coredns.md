# CoreDNS

## How kubeadm Handles CoreDNS

`kubeadm init` automatically deploys CoreDNS as a Deployment in `kube-system`. It:

1. Pulls the CoreDNS image (from the configured image repository)
2. Creates the `coredns` Deployment, `kube-dns` Service, and `coredns` ConfigMap
3. Leaves the pods in `Pending` state until a CNI plugin is installed

This is the correct and complete CoreDNS installation. No separate script is needed.

---

## Problem: `08-install-coredns.sh` is broken and redundant

### The manifest is a template, not valid YAML

The script applies one of two sources:

**Source 1 (online fallback):**
```
https://raw.githubusercontent.com/coredns/deployment/master/kubernetes/coredns.yaml.sed
```
The `.sed` extension is not a typo. This file contains shell variable placeholders like
`$DNS_SERVER_IP` and `$DNS_DOMAIN`. It is intended to be processed with `sed` before applying.
`kubectl apply` will fail with a YAML parse error.

**Source 2 (AMI pre-download):**
```
https://github.com/kubernetes/kubernetes/raw/release-1.29/cluster/addons/dns/coredns.yaml
```
This is the Kubernetes addon template for release-1.29 (wrong version). It contains
`__DNS__SERVICE_IP__` and `__DNS__DOMAIN__` placeholders. `kubectl apply` will also fail.

### Even if the manifest were valid, it conflicts with kubeadm

kubeadm has already created the CoreDNS Deployment, Service, ConfigMap, and RBAC resources.
Applying a second CoreDNS manifest on top will either:
- Fail due to resource conflicts
- Overwrite the kubeadm-managed resources with a different image and configuration
- Leave the cluster in an inconsistent state

---

## Fix

**Delete `08-install-coredns.sh` and remove it from `install-all.sh`.**

CoreDNS is fully managed by kubeadm. After CNI is working, the kubeadm-installed CoreDNS pods
will start automatically — no action required.

If you used the kubeadm config file from [01-kubeadm-init.md](01-kubeadm-init.md), the CoreDNS
image is already set to the correct EKS-D image at init time via:

```yaml
dns:
  imageRepository: public.ecr.aws/eks-distro/coredns
  imageTag: <eksd-coredns-tag>
```

If you need to patch an existing cluster to use the EKS-D CoreDNS image:

```bash
EKSD_COREDNS_TAG=<tag-from-release-manifest>
kubectl set image deployment/coredns \
  coredns=public.ecr.aws/eks-distro/coredns/coredns:${EKSD_COREDNS_TAG} \
  -n kube-system
```

---

## Why CoreDNS Pods Stay Pending

CoreDNS pods are `Pending` after `kubeadm init` because:

1. The control-plane node has the taint `node-role.kubernetes.io/control-plane:NoSchedule`
   — kubeadm's CoreDNS Deployment includes tolerations for this taint, so scheduling is not
   blocked by the taint.

2. **The real reason: no CNI plugin is installed yet.** Without CNI, the kubelet cannot set up
   pod networking, and pods stay in `ContainerCreating` or `Pending`. Once aws-node is running
   and has attached secondary IPs to the ENI, the node becomes `Ready` and CoreDNS pods start.

The correct fix for CoreDNS not starting is to fix the CNI installation, not to reinstall
CoreDNS.

---

## Verification

```bash
# CoreDNS pods should be Running after CNI is working
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Confirm EKS-D CoreDNS image is used
kubectl get deployment coredns -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: public.ecr.aws/eks-distro/coredns/coredns:v1.x.x-eks-1-33-...

# Test DNS resolution from a pod
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm -it \
  -- nslookup kubernetes.default.svc.cluster.local
```
