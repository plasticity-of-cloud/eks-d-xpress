# AWS Cloud Controller Manager

## Purpose

The AWS Cloud Controller Manager (cloud-provider-aws) is the external cloud provider for
Kubernetes on AWS. It is responsible for:

- **Node lifecycle**: Sets `spec.providerID` on each node (e.g., `aws:///us-east-1a/i-0abc123`)
  and removes nodes from the cluster when the EC2 instance is terminated
- **LoadBalancer services**: Creates and manages ELB/ALB/NLB for `Service` objects of type
  `LoadBalancer`
- **Route management**: Manages VPC route table entries for pod CIDRs (not needed with AWS VPC CNI)

Without the cloud controller manager, nodes never get a `providerID`. Karpenter uses
`providerID` to map Kubernetes nodes to EC2 instances for termination and replacement decisions.

---

## Problem: Missing from `install-all.sh`

`07.5-install-cloud-provider.sh` exists in the repo but is **never called** in `install-all.sh`.
The installation sequence jumps from CNI (step 7) directly to CoreDNS (step 8), skipping the
cloud provider entirely.

Consequences:
- Nodes have no `spec.providerID`
- Karpenter cannot identify which EC2 instance corresponds to a Kubernetes node
- `kubectl get nodes` shows nodes without a provider ID
- Node deletion by Karpenter may leave orphaned EC2 instances

---

## Fix

Add the cloud provider installation to `install-all.sh` between CNI and EBS CSI:

```bash
# Step 7.5: AWS Cloud Provider
echo "Step 7.5/11: Installing AWS Cloud Provider..."
bash "${SCRIPT_DIR}/07.5-install-cloud-provider.sh"
```

---

## Problem: `hostNetwork` patched after install instead of set at install time

`07.5-install-cloud-provider.sh` installs the Helm chart and then patches the DaemonSet:

```bash
helm install aws-cloud-controller-manager ... --wait

kubectl patch daemonset aws-cloud-controller-manager -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/hostNetwork","value":true}]'
```

The `--wait` flag causes `helm install` to wait for the DaemonSet to be ready before returning.
But the pod cannot become ready without `hostNetwork: true` (it needs to reach IMDS at
`169.254.169.254`, which is only reachable from the host network namespace). This creates a
deadlock: helm waits for ready, but the pod can't be ready until after the patch.

**Fix:** Set `hostNetwork` at install time:

```bash
helm install aws-cloud-controller-manager \
  aws-cloud-controller-manager/aws-cloud-controller-manager \
  --namespace kube-system \
  --set hostNetwork=true \
  --set nodeSelector."node-role\.kubernetes\.io/control-plane"="" \
  --set tolerations[0].key=node-role.kubernetes.io/control-plane \
  --set tolerations[0].effect=NoSchedule \
  --set args[0]=--v=2 \
  --set args[1]=--cloud-provider=aws \
  --set args[2]=--use-service-account-credentials=true \
  --wait
```

Remove the `kubectl patch` line.

---

## Dependency on `cloud-provider: external` in kubeadm config

The cloud controller manager only works correctly if `--cloud-provider=external` is set on:

1. **kubelet** — so it does not try to initialize the in-tree cloud provider
2. **kube-controller-manager** — so it does not run the in-tree node lifecycle controller
3. **kube-apiserver** — so it accepts the `node.cloudprovider.kubernetes.io/uninitialized` taint

All three are set via the kubeadm config file described in [01-kubeadm-init.md](01-kubeadm-init.md).
If the kubeadm config is not used, the cloud controller manager will conflict with the
in-tree controller and nodes may oscillate between initialized and uninitialized states.

---

## Verification

```bash
# Cloud controller manager pod should be Running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cloud-controller-manager

# Node should have providerID set
kubectl get node $(hostname) -o jsonpath='{.spec.providerID}'
# Expected: aws:///us-east-1a/i-0abc1234567890

# Node should not have the uninitialized taint
kubectl get node $(hostname) -o jsonpath='{.spec.taints}' | grep -v uninitialized
```
