# CNI Cold Boot Delay — Root Cause Analysis

> **Status: Fixed.** Option A below was implemented in `07-install-eks-d.sh` — the
> kube-proxy ClusterIP readiness check runs at the end of kubeadm init, before
> `08-install-cni.sh` is called.

## The Problem

On a fresh cold boot, the VPC CNI (`aws-node`) pod takes ~90 seconds to become ready.
After a cluster reset (warm system), the same pod starts in ~5 seconds.

## What's Happening

### The Race Condition

When Kubernetes boots, several things need to happen in order:

1. **kubeadm init** creates the control plane (API server, etcd, controller-manager, scheduler)
2. **kube-proxy** starts as a DaemonSet and programs iptables rules for Service ClusterIPs
3. **aws-node** (VPC CNI) starts and needs to talk to the API server

The problem: **aws-node starts before kube-proxy has finished programming iptables rules.**

### How Kubernetes Service Routing Works

When a pod wants to talk to the API server, it uses the ClusterIP service address:
```
https://10.96.0.1:443  (kubernetes.default.svc)
```

This is a virtual IP — it doesn't exist on any interface. **kube-proxy** makes it work by
adding iptables rules that redirect traffic to `10.96.0.1:443` → the real API server
at `10.0.1.162:6443`.

Without those iptables rules, packets to `10.96.0.1` go nowhere and time out.

### The Timeline on Cold Boot

```
23:08:08  kubeadm init completes
23:08:10  CNI manifest applied → aws-node pod scheduled
23:08:16  aws-node container starts, tries to reach API server at 10.96.0.1:443
23:08:21  TIMEOUT — kube-proxy hasn't programmed iptables yet
23:08:26  TIMEOUT
23:08:31  TIMEOUT
23:08:36  TIMEOUT
23:08:41  TIMEOUT
23:08:46  aws-node gives up on API server, proceeds without it
          (but gRPC health server on :50051 still not started)
23:08:25 → 23:09:30  Readiness probes fail (port 50051 not listening)
23:09:25  Liveness probe fails → container killed
23:09:45  Container restarted — by now kube-proxy rules are in place
23:09:47  aws-node connects to API server immediately, starts gRPC → READY
```

**Total delay: ~90 seconds** (30s API server timeout + 60s probe failures + restart)

### Why It Works After Reset

After a cluster reset, kube-proxy's iptables rules from the previous run are **flushed**
by the reset script. But when `kubeadm init` runs again, kube-proxy starts and programs
rules almost instantly because:

- containerd is already warm (pod starts in <1s)
- The API server is already running when kube-proxy starts
- By the time we apply the CNI manifest, kube-proxy rules are already in place

## The Fix

We need to ensure kube-proxy has programmed the `kubernetes` service iptables rules
before the aws-node pod starts trying to reach the API server.

### Option A: Wait for kube-proxy before applying CNI

Add a check in `08-install-cni.sh` that waits for the `kubernetes` service ClusterIP
to be routable before applying the CNI manifest:

```bash
# Wait for kube-proxy to program the kubernetes service iptables rules
echo "Waiting for kube-proxy to be ready..."
for i in $(seq 1 30); do
  if curl -sk --connect-timeout 2 https://10.96.0.1:443/version >/dev/null 2>&1; then
    echo "✓ kube-proxy rules active"
    break
  fi
  sleep 2
done
```

### Option B: Wait for kube-proxy pod readiness

```bash
kubectl wait --for=condition=ready pod -l k8s-app=kube-proxy -n kube-system --timeout=60s
```

### Option C: Use node IP instead of ClusterIP

Configure aws-node to use the node's actual IP for API server communication instead of
the ClusterIP. This bypasses the need for kube-proxy entirely. The VPC CNI supports
`KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT` environment variables.

## Recommendation

**Option A** is the most reliable — it directly verifies that the routing works before
proceeding. It doesn't depend on pod labels or readiness definitions, just actual
network connectivity.
