# AWS VPC CNI Configuration

## How AWS VPC CNI Works

AWS VPC CNI (aws-node DaemonSet) is not an overlay CNI. It does not create a virtual network.
Instead it:

1. Calls EC2 API to attach secondary private IPs to the node's ENI(s)
2. Writes those IPs into a local pool on the host
3. When a pod is created, assigns one of those VPC IPs directly to the pod's network namespace
4. Adds a host route so traffic to that pod IP goes to the correct veth pair

Pods get real VPC IPs. They are routable within the VPC without any encapsulation.

---

## Requirements

| Requirement | Status in current setup |
|-------------|------------------------|
| IAM: `AmazonEKS_CNI_Policy` on instance role | ✓ Attached via CDK infra stack (instance profile) |
| `hostNetwork: true` on aws-node DaemonSet | ✓ In the upstream manifest |
| Node reachable to EC2 API endpoint | ✓ Public subnet with internet access |
| No conflicting pod CIDR IPAM controller | ✗ `--pod-network-cidr` is set — see below |
| Node ProviderID set (for full operation) | ✗ Cloud provider not installed — see [04-cloud-provider.md](04-cloud-provider.md) |

---

## Problem: `--pod-network-cidr` activates conflicting IPAM

When `kubeadm init --pod-network-cidr=192.168.0.0/16` is used, kubeadm sets
`--cluster-cidr=192.168.0.0/16` on kube-controller-manager. This activates the built-in
node IPAM controller, which:

- Allocates a `/24` from `192.168.0.0/16` to each node
- Writes it to `node.spec.podCIDR`
- Adds routes for that CIDR on the node

AWS VPC CNI ignores `spec.podCIDR` and assigns VPC IPs. The result is:

- The node has routes for `192.168.0.0/24` pointing nowhere useful
- Pods get VPC IPs (e.g., `10.0.1.x`) but the routing table has stale overlay entries
- Intermittent connectivity failures, especially after node restarts

**Fix:** Remove `--pod-network-cidr` from kubeadm init entirely. See [01-kubeadm-init.md](01-kubeadm-init.md).

---

## Problem: Node name must resolve to EC2 instance

aws-node identifies the EC2 instance by calling `DescribeInstances` filtered on the node's
Kubernetes name. By default, kubelet sets the node name to the EC2 private DNS hostname
(e.g., `ip-10-0-1-42.us-east-1.compute.internal`). This matches what EC2 returns for
`PrivateDnsName`, so aws-node can find the instance.

If the node name is overridden (e.g., via `--hostname-override`), aws-node will fail to find
the instance and will not attach secondary IPs. Do not set `--hostname-override` unless you
also configure `AWS_VPC_K8S_CNI_NODE_PORT_SUPPORT` and related env vars.

---

## Problem: aws-node starts before ProviderID is set

With `--cloud-provider=external`, the node enters `NotReady` state after kubelet starts and
waits for the cloud controller manager to set `spec.providerID`. aws-node is a DaemonSet and
has tolerations for `NotReady`, so it will start. However, some versions of aws-node check
for ProviderID before attaching ENIs.

The correct order is:
1. Install AWS VPC CNI (aws-node DaemonSet created)
2. Install AWS Cloud Controller Manager (sets ProviderID on node)
3. aws-node completes ENI attachment, node becomes Ready
4. CoreDNS pods (already created by kubeadm) get IPs and start

See [04-cloud-provider.md](04-cloud-provider.md) for the cloud provider installation.

---

## Verification

```bash
# aws-node pod should be Running, not CrashLoopBackOff
kubectl get pods -n kube-system -l k8s-app=aws-node -o wide

# Node should have VPC IPs assigned to pods
kubectl get pods -A -o wide | grep -v '<none>'
# Pod IPs should be in the VPC CIDR (e.g., 10.0.x.x), not 192.168.x.x

# Check aws-node logs for ENI attachment
kubectl logs -n kube-system -l k8s-app=aws-node --tail=50
# Should see: "Successfully assigned ... IP addresses"

# Verify no overlay routes on the node
ip route | grep 192.168
# Expected: no output
```
