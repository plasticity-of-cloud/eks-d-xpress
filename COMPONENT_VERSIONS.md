# Component Versions

Pinned versions consumed by the AMI build. Bump these when releasing a new version.

| Component | Variable | Current |
|-----------|----------|---------|
| eks-d-xpress-control-plane | `EKS_DX_CONTROL_PLANE_VERSION` | `1.0.0-rc1` |
| Kubernetes (EKS-D) | `KUBERNETES_VERSION` | `1.35` |
| cert-manager | `CERT_MANAGER_VERSION` | `v1.17.1` |
| Karpenter | `KARPENTER_VERSION` | `1.10.0` |

## Updating

1. Update the version in this file
2. Update `ami-builder/scripts/component-versions.env` (sourced at build time)
3. Open a PR — the `build-ami.yml` workflow will validate and publish a new AMI on merge to `main`
