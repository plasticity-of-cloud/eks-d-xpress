# EKS-DX Pod Identity Integration — Requirements

## Current State

- ✅ `eks-d-setup/14-install-eks-dx-pod-identity.sh` — script exists, handles:
  - JWKS extraction from running cluster
  - Cluster registration with EKS-DX control plane (`eks-dx create cluster`)
  - Helm install of `eks-dx-auth-proxy`
  - Helm install of `eks-dx-pod-identity-webhook`
  - Graceful skip if `EKS_DX_ENDPOINT` not set

- ❌ Not wired into `setup-eks-d.sh` boot sequence
- ❌ Helm charts not pre-pulled in AMI builder
- ❌ Container images not pre-pulled in AMI builder
- ❌ `eks-dx` CLI binary not installed in AMI
- ❌ No progress reporting integrated

## AMI Builder Requirements

Add to `ami-builder/scripts/install.sh`:

```bash
# Pre-pull EKS-DX Pod Identity charts (from private ECR or bundled artifact)
echo "==> Pre-pulling EKS-DX Pod Identity charts..."
# Source TBD — either private ECR OCI registry or S3 artifact
# helm pull oci://<registry>/eks-dx-auth-proxy --destination /tmp
# helm pull oci://<registry>/eks-dx-pod-identity-webhook --destination /tmp

# Install eks-dx CLI
echo "==> Installing eks-dx CLI..."
# Source TBD — S3 artifact or GitHub release
# curl -sL <url> -o /usr/local/bin/eks-dx && chmod +x /usr/local/bin/eks-dx

# Pre-pull container images for eks-dx-auth-proxy and eks-dx-pod-identity-webhook
# sudo ctr -n k8s.io images pull <registry>/eks-dx-auth-proxy:<tag>
# sudo ctr -n k8s.io images pull <registry>/eks-dx-pod-identity-webhook:<tag>
```

### Artifacts needed from eks-dx-control-plane repo:
1. `eks-dx` CLI binary (arm64 + x86_64)
2. `eks-dx-auth-proxy` Helm chart tarball
3. `eks-dx-pod-identity-webhook` Helm chart tarball
4. Container images for both components

## Boot Sequence Integration

In `setup-eks-d.sh`, add after CloudWatch (step 10) as an optional step:

```bash
# Step 11 (optional): EKS-DX Pod Identity integration
# Only runs if EKS_DX_ENDPOINT is set (provisioned by Lambda, not manual dev setup)
if [ -n "${EKS_DX_ENDPOINT:-}" ]; then
  echo "Step 11: Registering with EKS-DX control plane..."
  update_progress "registering" "Registering cluster with EKS-DX" 97
  bash "${SCRIPT_DIR}/14-install-eks-dx-pod-identity.sh"
fi
```

## Progress Reporting

With the modular plugin architecture, this step belongs in a new group:

```
addons/
├── identity/                    # Pod identity & auth
│   └── eks-dx-pod-identity.sh   # Registers cluster + installs webhook
```

Progress mapping when integrated:
| Phase | Progress | Description |
|-------|----------|-------------|
| Core complete | 65% | Node ready, cert-manager installed |
| Addons (parallel) | 70-95% | storage + orchestration + telemetry |
| EKS-DX registration | 97% | Cluster registered, webhooks installed |
| Ready | 100% | All components running |

Note: EKS-DX registration should run AFTER cert-manager (needs webhook TLS certs)
and AFTER the cluster is fully functional. It's the last step before `ready`.

## Environment Variables

Passed via EC2 user-data (set by provisioner Lambda):

```bash
EKS_DX_ENDPOINT=https://<function-url>.lambda-url.us-east-1.on.aws
EKS_DX_API_URL=https://<api-id>.execute-api.us-east-1.amazonaws.com/prod
EKS_DX_TENANTS_TABLE=eks-dx-tenants
```

For dev/manual provisioning (current `provision-tenant.sh`), these are not set
and the script gracefully skips — no Pod Identity integration in dev mode.

## IAM Permissions

The instance profile role needs (added by provisioner Lambda, not Terraform):

| Action | Resource | Purpose |
|--------|----------|---------|
| `lambda:InvokeFunctionUrl` | EKS-DX Lambda | Cluster registration |
| `execute-api:Invoke` | EKS-DX API Gateway | In-cluster component auth |

## User-Data Changes

When provisioned by Lambda (not Terraform), user-data includes additional env vars:

```bash
#!/bin/bash
mkdir -p /opt/eks-d
cat > /opt/eks-d/cluster.env <<CONF
TENANT_ID="<tenant-id>"
CLUSTER_NAME="<cluster-name>"
EKS_DX_ENDPOINT="<lambda-function-url>"
EKS_DX_API_URL="<api-gateway-url>"
EKS_DX_TENANTS_TABLE="eks-dx-tenants"
CONF
```

The boot script sources `cluster.env` and the presence of `EKS_DX_ENDPOINT`
triggers the Pod Identity integration step.
