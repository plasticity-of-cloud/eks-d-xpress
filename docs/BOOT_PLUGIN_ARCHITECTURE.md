# Boot Script Plugin Architecture

## Overview

The boot sequence is split into two phases:
1. **Core** — sequential scripts that establish the cluster (strict ordering required)
2. **Addons** — parallel groups that install optional components (no ordering between groups)

Addon groups run **all in parallel** with a concurrency limit equal to the number of CPU cores on the instance. Customers add scripts to the appropriate group folder.

## Directory Structure

```
eks-d-setup/
├── setup-eks-d.sh              # Runner: orchestrates core + addon phases
├── core/                       # Phase 1: Sequential, strict order
│   ├── 01-prepare-etcd.sh
│   ├── 02-install-aws-iam-authenticator.sh
│   ├── 03-install-eks-d.sh
│   ├── 04-install-cni.sh
│   ├── 05-install-cloud-provider.sh
│   └── 06-configure-node.sh
├── addons/
│   ├── storage/                # CSI drivers
│   │   ├── ebs-csi.sh
│   │   ├── # nfs-csi.sh       (customer adds)
│   │   ├── # fsx-csi.sh       (customer adds)
│   │   └── # mountpoint-s3.sh (customer adds)
│   ├── orchestration/          # Scheduling & scaling
│   │   └── karpenter.sh
│   └── telemetry/              # Observability
│       ├── metrics-server.sh
│       ├── cloudwatch.sh
│       └── # adot.sh          (customer adds)
```

## Execution Model

```
Phase 1: Core (sequential)
  core/01-prepare-etcd.sh
  core/02-install-aws-iam-authenticator.sh
  core/03-install-eks-d.sh          # includes kube-proxy readiness wait
  core/04-install-cni.sh
  core/05-install-cloud-provider.sh
  core/06-configure-node.sh         # node becomes Ready

Phase 2: Addons (parallel, concurrency = nproc)
  ┌─ addons/storage/ebs-csi.sh
  ├─ addons/orchestration/karpenter.sh
  ├─ addons/telemetry/metrics-server.sh
  └─ addons/telemetry/cloudwatch.sh
  (all run concurrently, max `nproc` jobs at a time)
```

## Runner Logic (setup-eks-d.sh)

```bash
# Phase 1: Core — sequential
for script in core/[0-9]*.sh; do
  bash "$script"
done

# Phase 2: Addons — parallel with concurrency limit
MAX_JOBS=$(nproc)
find addons/ -name '*.sh' -executable | sort | while read script; do
  while [ "$(jobs -r | wc -l)" -ge "$MAX_JOBS" ]; do sleep 1; done
  bash "$script" &
done
wait
```

## Adding Custom Addons

Customers drop executable `.sh` scripts into the appropriate folder:

```bash
# Example: Add Mountpoint for S3 CSI driver
cp my-mountpoint-s3.sh /opt/eks-d-setup/addons/storage/mountpoint-s3.sh
chmod +x /opt/eks-d-setup/addons/storage/mountpoint-s3.sh
```

### Script Requirements

- Must be idempotent (safe to re-run)
- Must use `set -e` for fail-fast
- Must not depend on other addon scripts (no ordering guarantees between addons)
- Should use pre-cached helm charts/images from `/opt/eks-d/charts/` when available
- Logs go to stdout/stderr (captured by the runner)

### Script Template

```bash
#!/bin/bash
set -e

echo "Installing <component>..."

# Use pre-cached chart if available
CHART="/opt/eks-d/charts/<component>.tgz"
if [ -f "$CHART" ]; then
  helm install <release> "$CHART" -n <namespace> --create-namespace
else
  helm install <release> <repo>/<chart> -n <namespace> --create-namespace
fi

# Wait for readiness
kubectl wait --for=condition=available deployment/<name> -n <namespace> --timeout=60s || {
  echo "Warning: <component> not ready within timeout, but may still become ready"
}

echo "✓ <component> installed"
```

## Concurrency Control

- `MAX_JOBS=$(nproc)` — limits parallel scripts to CPU core count
- On m7g.large (2 cores): max 2 concurrent addon installs
- On m7g.xlarge (4 cores): max 4 concurrent addon installs
- Prevents API server and containerd overload on smaller instances

## Expected Boot Time Impact

With 2 cores (m7g.large), addons run 2 at a time instead of 4 sequentially:
- Before: EBS(6s) + Karpenter(3s) + Metrics(22s) + CloudWatch(15s) = ~46s
- After: max(EBS+Karpenter, Metrics+CloudWatch) ≈ ~25s
- Savings: ~20s

With 4 cores: all 4 run simultaneously ≈ ~22s (limited by slowest addon).
