# Boot Time Issues — 2026-05-22

Analysis of cold boot via `eks-dx-boot.service` on fresh tenant provision.
Total time: **180s (killed by systemd timeout)** — should be ~90s.

## Timeline

| Time | Duration | Step |
|------|----------|------|
| +0s | 3s | IMDS check + etcd + iam-authenticator |
| +3s | **10s** | **Downloading EKS-D binaries (kubeadm, kubelet, kubectl)** |
| +13s | 26s | kubeadm init (certs, static pods, control plane healthy) |
| +39s | **65s** | **VPC CNI install + aws-node pod readiness** |
| +104s | 12s | Cloud controller manager helm + CCM wait timeout |
| +116s | 11s | CCM node initialization |
| +127s | 4s | EBS CSI helm install |
| +131s | **0s** | **EBS CSI node wait — instant failure (wrong label selector)** |
| +131s | **30s** | **Metrics server wait timeout** |
| +161s | 19s | Karpenter + CloudWatch (killed at 180s) |

## Issues & Fixes

### 1. ✅ FIXED — EBS CSI node pod wait uses wrong label selector

**File:** `eks-d-setup/13-install-ebs-csi.sh`  
**Commit:** `6de0235`

**Problem:** Wait used `app.kubernetes.io/component=node` but chart v2.60.1 labels all pods `component=csi-driver`. Instant failure with "no matching resources found".

**Fix:** Changed selector to `app.kubernetes.io/component=csi-driver`.

### 2. ✅ FIXED — EKS-D binaries downloaded at boot (10s wasted)

**Files:** `ami-builder/scripts/install.sh`, `eks-d-setup/07-install-eks-d.sh`  
**Commit:** `81ed425`

**Problem:** kubeadm, kubelet, kubectl (~178MB) downloaded from `distro.eks.amazonaws.com` on every boot.

**Fix:** Pre-install binaries during AMI build. Boot script skips download if already present at `/usr/local/bin/`.

### 3. ✅ FIXED — VPC CNI double rollout (40-50s wasted)

**File:** `eks-d-setup/08-install-cni.sh`  
**Commit:** `c66fa60`

**Problem:** Script applied the CNI manifest, waited for the pod to be ready, then ran `kubectl set env AWS_VPC_K8S_CNI_EXTERNALSNAT=false` — which triggered a full DaemonSet rollout (kill pod, create new pod, wait again). The env var was already set to `false` in the manifest.

**Root cause from events:**
1. First pod starts, readiness probes fail on port 50051 for ~15s
2. `kubectl set env` patches DaemonSet → kills first pod
3. Second pod goes through full startup cycle again

**Fix:** Removed redundant `kubectl set env` — value is already in the pre-cached manifest.

### 4. Metrics server wait times out (30s wasted)

The metrics-server deployment takes >30s to become ready on cold boot because it depends on the API server aggregation layer being fully initialized. The 30s timeout is too short.

**Status:** Not yet fixed. Non-critical — metrics-server comes up eventually.

### 5. SystemD timeout (180s)

With fixes #1-3 applied, cold boot should complete in ~100-120s, well within the 180s limit.

**Status:** No change needed if other fixes land.

## Expected Boot Time After Fixes

| Step | Before | After |
|------|--------|-------|
| EKS-D binaries | 10s | 0s (pre-baked) |
| VPC CNI | 65s | ~20s (single rollout) |
| EBS CSI wait | 0s (failed) | ~10s (correct selector) |
| **Total estimated** | **>180s** | **~100-120s** |

