# AMI Builder — `install.sh` Modularization

## Status: Accepted, pending implementation

## Problem

`ami-builder/scripts/install.sh` is a 517-line monolith with two very different halves:

- **Lines 1–~200**: Instance configuration — binary installs, system config, tool setup.
  Already partially modular (calls 00/01/02/04 sub-scripts).
- **Lines ~200–517**: Component pre-warming — Helm chart downloads + container image
  pre-pulls for every component that runs at boot.

The second half grows linearly as components are added. When a Packer build fails at
"line 412" there is no context about which component failed. Adding a new CSI driver
means editing the monolith in two places (charts section + images section).

## Target Structure

```
ami-builder/scripts/
├── install.sh                      # orchestrator (~120 lines after split)
├── 00-configure-containerd.sh      # unchanged
├── 01-install-base.sh              # unchanged
├── 02-install-docker.sh            # unchanged
├── 04-install-helm.sh              # unchanged
└── components/                     # NEW — one file per component
    ├── cert-manager.sh
    ├── karpenter.sh
    ├── ebs-csi.sh
    ├── cloud-provider-aws.sh
    ├── vpc-cni.sh                  # includes CNI binary pre-baking
    ├── cloudwatch.sh
    ├── system-images.sh            # metrics-server, aws-iam-authenticator, kubectl
    └── eks-dx.sh                   # conditional on INSTALL_EKS_DX=true
```

## Why Per-Component, Not Two Files

A `10-pull-charts.sh` + `11-pull-images.sh` split would still be 120-line files where
cert-manager and karpenter failures are indistinguishable. Per-component gives:

- **One failure domain per file** — Packer logs name the script, not the line number
- **Open/closed** — adding a component = adding one file, no edits to existing scripts
- **Conditional isolation** — `INSTALL_EKS_DX` guard lives only in `eks-dx.sh`
- **Independent re-runnability** — a failed chart pull can be retried by running one script

## Shared State: `/tmp/ami-build.env`

`install.sh` resolves ECR credentials once after containerd is installed, then writes
them to a temp env file. All component scripts source it.

```bash
# Written by install.sh after ECR auth:
cat > /tmp/ami-build.env <<EOF
ECR_REGISTRY=${ECR_REGISTRY}
PUBLIC_ECR_CACHE=${ECR_REGISTRY}/public-ecr
K8S_REGISTRY_CACHE=${ECR_REGISTRY}/registry-k8s-io
QUAY_CACHE=${ECR_REGISTRY}/quay-io
ECR_CTR_USER=AWS:${ECR_PASSWORD}
REGION=${REGION}
ACCOUNT_ID=${ACCOUNT_ID}
INSTALL_EKS_DX=${INSTALL_EKS_DX:-false}
EKS_DX_CONTROL_PLANE_VERSION=${EKS_DX_CONTROL_PLANE_VERSION}
EOF
```

All component scripts start with:
```bash
source /tmp/ami-build.env
CHARTS_DIR="/opt/eks-d-setup/charts"
```

## Component Script Interface

Each script must:
- `set -e` — fail fast
- Source `/tmp/ami-build.env`
- Pull its Helm chart(s) to `/opt/eks-d-setup/charts/` (if applicable)
- Pull its container images via `ctr -n k8s.io images pull`
- Print `✓ <component> ready` on success
- Be idempotent (safe to re-run)

## Component Responsibilities

| Script | Chart source | Image source | Notes |
|--------|-------------|--------------|-------|
| `cert-manager.sh` | jetstack Helm repo | `quay.io` → `QUAY_CACHE` | |
| `karpenter.sh` | OCI `public.ecr.aws/karpenter` | `public.ecr.aws` (direct) | No pull-through for karpenter images |
| `ebs-csi.sh` | `kubernetes-sigs` Helm repo | `public.ecr.aws` → `PUBLIC_ECR_CACHE` | Filter out windows/gpu images |
| `cloud-provider-aws.sh` | `kubernetes/cloud-provider-aws` Helm repo | `registry.k8s.io` → `K8S_REGISTRY_CACHE` | |
| `vpc-cni.sh` | No chart — downloads manifest from GitHub | `602401143452.dkr.ecr.us-west-2` (direct auth) | Also pre-bakes `/opt/cni/bin` from init container; patches manifest for prefix delegation |
| `cloudwatch.sh` | `aws-observability` Helm repo | `public.ecr.aws` → `PUBLIC_ECR_CACHE` | |
| `system-images.sh` | No chart | Various | metrics-server, aws-iam-authenticator, kubectl (for kubelet-csr-approver) |
| `eks-dx.sh` | OCI GHCR charts | `ghcr.io` (direct) | No-op if `INSTALL_EKS_DX != true`; also pulls eks-pod-identity-agent |

## `install.sh` After Split

```
1. Version discovery (EKS-D manifest, component-versions.env)
2. Binary installs (kubeadm, kubelet, kubectl, ecr-credential-provider, syft, eks-dx CLI)
3. System config (kubelet service, ECR credential provider config, kernel params,
                  systemd-networkd drop-in, swap disable)
4. Tool installation (calls 00/01/02/04 sub-scripts)
5. ECR auth → write /tmp/ami-build.env
6. Copy eks-d-setup scripts + karpenter node-pools to /opt/eks-d-setup/
7. Run component scripts (components/*.sh) — each prints ✓ on success
8. Install eks-dx-boot.service
9. Cleanup (helm ECR logout, image unpack)
```

## Execution in `install.sh`

```bash
# Run each component script
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
```

Order matters only for `vpc-cni.sh` (must run after `install.sh` writes
`/opt/eks-d/manifests/` — already handled since that directory is created by
`install.sh` before component scripts run).

## Migration Notes

- No Packer HCL changes needed — the `file` provisioner already uploads all of
  `ami-builder/scripts/` recursively; `components/` is a subdirectory of that
- `extract-images.py` path: `${SCRIPT_DIR}/../extract-images.py` from component scripts,
  or pass `SCRIPT_DIR` via `/tmp/ami-build.env`
- The `/tmp/ami-build.env` file is ephemeral on the builder instance — no security concern
