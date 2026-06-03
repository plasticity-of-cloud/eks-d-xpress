# Deployment Guide

## Prerequisites

Before deploying, ensure you have:

- AWS CLI configured with appropriate permissions
- SSH key pair created in target region
- Clone of this repository on your local machine

## Deployment Steps

### 1. Deploy Shared VPC

The VPC provides networking for all developer environments.

```bash
cd infrastructure
./provision-shared-infra.sh us-east-1
```

This creates:
- VPC with CIDR 10.0.0.0/16
- Public and private subnets
- NAT Gateway
- Internet Gateway
- Security groups

### 2. Deploy Developer Stack

Deploy an EC2 instance with EKS-D for a team member:

```bash
# Automated setup (user data runs installation)
./deploy-developer.sh alice 1 my-key-pair true

# Manual setup (SSH and run scripts yourself)
./deploy-developer.sh alice 1 my-key-pair false
```

Parameters:
- `alice` - Team member identifier (used in resource names)
- `1` - Instance number
- `my-key-pair` - SSH key pair name
- `true/false` - Enable/disable automated user data

### 3. Verify Installation

After the instance is ready (wait ~10 minutes for automated setup):

```bash
# SSH to the instance
ssh -i ~/.ssh/my-key-pair.pem ubuntu@<public-ip>

# Verify EKS-D is running
kubectl get nodes
kubectl get pods -A
```

### 4. Configure Karpenter

On the control plane instance:

```bash
# Set environment variables
export CLUSTER_NAME=<your-cluster-name>
export AWS_REGION=us-east-1

# Install Karpenter
cd ~/ecp-eks-dx-infra/karpenter-config
./install-karpenter.sh

# Configure NodePools
cd ../node-pools
./configure-nodepools.sh alice us-east-1
```

### 5. Deploy Test Workload

```bash
kubectl apply -f node-pools/test-workload.yaml
kubectl get nodes -w
```

## Manual Setup (Alternative)

If you disabled auto-setup in step 2:

```bash
# SSH to instance
ssh -i ~/.ssh/my-key-pair.pem ubuntu@<public-ip>

# Clone repository
git clone <repository-url>
cd ecp-eks-dx-infra/eks-d-setup

# Install all components
./install-all.sh

# Verify
kubectl get nodes
```

## Cleanup

```bash
# Delete workloads
kubectl delete -f node-pools/test-workload.yaml

# Wait for nodes to terminate
kubectl get nodes -w

# Delete CloudFormation stacks
aws cloudformation delete-stack --stack-name eks-d-alice --region us-east-1
aws cloudformation delete-stack --stack-name eks-d-shared-vpc --region us-east-1
```

## Troubleshooting

### Karpenter not provisioning nodes

```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Check node events
kubectl get events --field-selector reason=ProvisioningSucceeded
```

### Worker nodes not joining

```bash
# Check security groups
kubectl get events --sort-by='.lastTimestamp' | head -20
```

### SSH access issues

- Verify key pair exists: `aws ec2 describe-key-pairs --region us-east-1`
- Check security group allows SSH (port 22)
- Verify instance is running and public IP is correct
