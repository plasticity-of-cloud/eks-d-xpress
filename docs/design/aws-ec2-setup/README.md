# EKS-D Single-Node EC2 Setup — Design Documents

This directory documents the required configuration to make a self-managed EKS-D cluster on EC2
behave equivalently to an EKS managed cluster.

## Documents

| Document | Description |
|----------|-------------|
| [01-kubeadm-init.md](01-kubeadm-init.md) | kubeadm configuration for EKS-D images and external cloud provider |
| [02-aws-vpc-cni.md](02-aws-vpc-cni.md) | AWS VPC CNI requirements and pod-network-cidr conflict |
| [03-coredns.md](03-coredns.md) | CoreDNS — why the install script is wrong and what to do instead |
| [04-cloud-provider.md](04-cloud-provider.md) | AWS Cloud Controller Manager — missing from install-all.sh |
| [05-containerd.md](05-containerd.md) | containerd sandbox image and cgroup driver configuration |
| [06-infrastructure.md](06-infrastructure.md) | Terraform: IMDSv2 hop limit and security group rules |
| [07-install-order.md](07-install-order.md) | Corrected installation order and verification checklist |
| [08-karpenter.md](08-karpenter.md) | Karpenter OCI registry migration — old helm repo is dead |

## Problem Summary

The current setup installs EKS-D binaries (kubelet, kubeadm, kubectl) from the EKS-D release
manifest but runs `kubeadm init` without a config file, resulting in:

- Upstream `registry.k8s.io` container images instead of EKS-D images
- No `cloud-provider: external` on control plane components
- `--pod-network-cidr` set, which conflicts with AWS VPC CNI
- CoreDNS installed twice (kubeadm + broken script)
- AWS Cloud Controller Manager never installed
- containerd using wrong pause image
- EC2 metadata hop limit blocking containers
- Security group blocking API server and kubelet ports
