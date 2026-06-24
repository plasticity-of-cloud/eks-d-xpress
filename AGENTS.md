# EKS-D-Xpress - AI Agent Context Guide

## Project Overview

EKS-D-Xpress is a rapid Kubernetes deployment system that creates EKS-compatible clusters with Karpenter autoscaling in under 3 minutes. The system combines infrastructure automation (AWS CDK), custom AMI building (Packer), and streamlined EKS-D installation to deliver production-ready clusters quickly.

## Repository Structure and Navigation

### Core Directories
```
eks-d-xpress/
├── ami-builder/          # AMI creation and signing (Packer + Java CDK)
├── eks-d-setup/          # Sequential installation scripts (05-17)  
├── node-pools/           # Karpenter node pool configuration
├── monitoring/           # CloudWatch and metrics setup
├── docs/                 # Project documentation
└── .agents/summary/      # Generated documentation (this guide)
```

### Key Entry Points
- **`ami-builder/eks-d-xpress.pkr.hcl`**: Packer configuration for golden AMI
- **`eks-d-setup/setup-eks-d.sh`**: Master installation orchestrator (~135 lines)
- **`ami-builder/scripts/install.sh`**: Comprehensive AMI provisioning (~517 lines)
- **`DEPLOYMENT_GUIDE.md`**: Redirect — see `docs/user-guides/deployment.md`
- **`COMPONENT_VERSIONS.md`**: Pinned component versions and compatibility

## Architecture Overview

The system uses a three-phase approach:
1. **CDK Pre-build Setup**: AWS CDK provisions IAM roles, OIDC trust, and instance profiles so GitHub Actions can connect to AWS and run Packer — CDK is not used for cluster infrastructure
2. **AMI Building**: Packer creates golden AMIs with pre-installed components (triggered from GitHub Actions using the CDK-provisioned IAM resources)
3. **Cluster Deployment**: Numbered scripts (05-17) install EKS-D sequentially

### Installation Sequence
```
05-prepare-etcd.sh → 06-install-aws-iam-authenticator.sh → 07-install-eks-d.sh → 
08-install-cni.sh → 09-install-cloud-provider.sh → 10-configure-node.sh →
11-install-cert-manager.sh → 11b-install-kubelet-csr-approver.sh → 
12-install-eks-dx-pod-identity.sh → 13-install-ebs-csi.sh → 
14-install-metrics-server.sh → 15-install-karpenter.sh → 
16-install-cloudwatch.sh → 17-monitor-cloudwatch-rollout.sh →
18-install-eks-dx-karpenter-support.sh
```

## Repo-Specific Tools and Patterns

### Build System
- **AMI Builder**: `ami-builder/build-golden-amis.sh` - orchestrates Packer builds
- **CDK Stack**: `ami-builder/cdk/` - Java CDK for IAM role management  
- **Cleanup Tools**: `ami-builder/cleanup-amis.sh` - removes old AMIs
- **Progress Tracking**: `eks-d-setup/progress.sh` - installation progress functions

### Configuration Management
- **Component Versions**: Centralized in `COMPONENT_VERSIONS.md` with compatibility matrix
- **EKS-D Discovery**: `ami-builder/scripts/discover-eks-d.sh` - finds latest releases
- **Image Pre-loading**: `ami-builder/scripts/extract-images.py` - container image extraction
- **Reset Capability**: `eks-d-setup/reset-cluster.sh` - cluster cleanup and reset

### Security Patterns
- **AMI Signing**: Cryptographic signing of golden AMIs
- **Pod Identity**: EKS Pod Identity integration (newer than IRSA)
- **CSR Automation**: Kubelet certificate signing automation
- **IAM Integration**: AWS IAM Authenticator for cluster authentication

## Development Workflow Deviations

### Non-Standard Patterns
- **Numbered Scripts**: Installation uses numbered sequence (05-17) vs typical single installer
- **Golden AMIs**: Heavy use of pre-built AMIs vs runtime provisioning
- **Java CDK**: Java CDK solely for pre-build IAM setup enabling Packer to run in AWS from GitHub CI (not for cluster infrastructure)
- **Progress Functions**: Built-in progress reporting system across scripts

### Script Organization
- **Modular Installation**: Each component gets its own numbered script
- **Dependency Management**: Scripts must run in numerical order
- **Error Handling**: Each script includes failure recovery mechanisms
- **Environment Setup**: Scripts source common configuration from environment

## Critical Configuration Files

### Discovered from Repository Structure
- **`.tool-versions`**: asdf version management (present)
- **`Makefile`**: Build automation in `ami-builder/`
- **`.github/`**: GitHub Actions CI/CD workflows
- **`ami-builder/cdk/`**: AWS CDK infrastructure stack

### Component Integration
- **EKS-D Releases**: Direct integration with AWS EKS-D release manifests
- **Karpenter Integration**: NodePool and EC2NodeClass configurations
- **CloudWatch Integration**: Automated agent deployment and configuration
- **VPC CNI**: AWS-specific networking with ENI management

## Language-Specific Considerations

### Shell Scripts (Primary)
- Extensive use of bash scripting for installation automation
- Functions defined in `progress.sh` for common operations
- Environment variable heavy configuration
- Error handling with exit codes and logging

### Java (CDK Components)  
- **`EksDXpressPackerIamStack.java`**: IAM stack solely for provisioning infrastructure that allows Packer to execute AMI builds via GitHub Actions (GitHub → AWS connection)
- CDK is **not** used for cluster infrastructure — its only role is pre-build setup (IAM roles, OIDC trust, instance profiles) enabling Packer to run in AWS from GitHub CI
- Maven-based build system
- AWS CDK v2 constructs for infrastructure

### HCL (Packer)
- **`eks-d-xpress.pkr.hcl`**: Packer configuration with provisioners
- Shell script provisioning chain
- AMI metadata and tagging

## Key Dependencies and Versions

### Infrastructure Requirements
- Ubuntu 22.04 LTS base images
- containerd container runtime
- AWS CDK for infrastructure management
- Java 17+ for CDK stack deployment

### Kubernetes Components
- EKS-D versions: 1.35.4 (eks-1-35-9) or 1.36.0 (eks-1-36-2)
- etcd 3.5.21 (shared across versions)
- AWS VPC CNI v1.19.0
- Karpenter for node autoscaling

## Quick Start for Development

1. **Infrastructure Setup**: Configure CDK in `ami-builder/cdk/` directory
2. **AMI Building**: Run `ami-builder/build-golden-amis.sh` 
3. **Cluster Deployment**: Execute `eks-d-setup/setup-eks-d.sh`
4. **Node Configuration**: Use `node-pools/configure-nodepools.sh`

## Custom Instructions
<!-- This section is for human and agent-maintained operational knowledge.
     Add repo-specific conventions, gotchas, and workflow rules here.
     This section is preserved exactly as-is when re-running codebase-summary. -->
