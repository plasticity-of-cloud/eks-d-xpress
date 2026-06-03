# EKS-D Component Versions

## Version Compatibility Matrix

EKS-D reuses compatible component versions across releases. Not all components are rebuilt for each Kubernetes version - only when changes are required.

### EKS-D 1.35.9 Component Versions

| Component | Version | Image Tag | Notes |
|-----------|---------|-----------|-------|
| **Core Kubernetes** | | | |
| kube-apiserver | v1.35.4 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |
| kube-controller-manager | v1.35.4 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |
| kube-scheduler | v1.35.4 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |
| kubelet | v1.35.4 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |
| pause | v1.35.4 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |
| **Authentication** | | | |
| aws-iam-authenticator | v0.7.13 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |
| **Add-ons** | | | |
| metrics-server | v0.7.2 | `eks-1-32-8` | ⚠️ Reused from 1.32 (compatible) |
| coredns | v1.11.3 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |
| **CNI & Storage** | | | |
| aws-vpc-cni | v1.19.0 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |
| aws-ebs-csi-driver | v1.38.0 | `eks-1-35-9` | ✅ Rebuilt for 1.35 |

## Why Some Components Keep Older Tags

**This is normal and expected behavior:**

1. **Compatibility**: Components like metrics-server v0.7.2 are fully compatible with Kubernetes 1.35
2. **Efficiency**: AWS doesn't rebuild components unnecessarily 
3. **Stability**: Reusing tested versions reduces risk
4. **Official**: These versions are specified in the official EKS-D release manifest

## Verification

To verify component versions for any EKS-D release:

```bash
# Download the official manifest
curl -s https://distro.eks.amazonaws.com/kubernetes-1-35/kubernetes-1-35-eks-9.yaml

# Check specific component
curl -s https://distro.eks.amazonaws.com/kubernetes-1-35/kubernetes-1-35-eks-9.yaml | grep -A5 -B5 metrics-server
```

## Customer Impact

- ✅ **Functionality**: All components work correctly regardless of tag version
- ✅ **Security**: All images receive security updates through their respective channels
- ✅ **Support**: AWS supports the exact versions specified in the release manifest
- ⚠️ **Monitoring**: Some monitoring tools may flag "version mismatches" - this is expected

## References

- [EKS-D Release Manifests](https://distro.eks.amazonaws.com/)
- [EKS-D GitHub Releases](https://github.com/aws/eks-distro/releases)
