# EKS-D-Xpress Deployment Guide

## Prerequisites

1. **AWS CLI configured** with appropriate permissions
2. **Terraform installed** (>= 1.0)
3. **EC2 Key Pair** created in target region
4. **Compute Savings Plan** (optional but recommended for cost savings)

## Step-by-Step Deployment

### 1. Infrastructure Setup

```bash
cd infrastructure

# Copy and customize variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your team member details

# Deploy infrastructure
terraform init
terraform plan
terraform apply
```

**Important Terraform Outputs:**
- `control_plane_public_ip`: SSH access IP
- `worker_node_instance_profile`: Needed for Karpenter
- `cluster_name`: Your cluster identifier

### 2. Connect to Control Plane

```bash
# Get SSH command from Terraform output
terraform output ssh_command

# SSH to control plane
ssh -i ~/.ssh/your-key.pem ubuntu@<control-plane-ip>
```

### 3. Install EKS-D

```bash
cd /home/ubuntu
git clone <this-repo> # Or copy files
cd ecp-eks-dx-infra/eks-d-setup

# Install EKS-D
./install.sh

# Verify installation
kubectl get nodes
kubectl get pods -A
```

### 4. Install Karpenter

```bash
cd ../karpenter-config

# Set environment variables from Terraform outputs
export CLUSTER_NAME=$(terraform output -raw cluster_name)
export AWS_REGION=us-east-1

# Install Karpenter
./install-karpenter.sh

# Verify Karpenter
kubectl get pods -n karpenter
```

### 5. Configure NodePools

```bash
cd ../node-pools

# Configure NodePool templates
export INSTANCE_PROFILE_NAME=$(terraform output -raw worker_node_instance_profile)
./configure-nodepools.sh

# Apply Spot NodePool
kubectl apply -f spot-nodepool.yaml

# Verify NodePool
kubectl get nodepool
kubectl get ec2nodeclass
```

### 6. Test Workload Deployment

```bash
# Deploy test workloads
kubectl apply -f test-workload.yaml

# Watch nodes being provisioned
kubectl get nodes -w

# Check pod placement
kubectl get pods -o wide
```

### 7. Setup Monitoring (Optional)

```bash
cd ../monitoring

# Update cluster name in CloudWatch config
sed -i "s/REPLACE_WITH_CLUSTER_NAME/${CLUSTER_NAME}/g" cloudwatch-setup.yaml

# Deploy CloudWatch agent
kubectl apply -f cloudwatch-setup.yaml
```

## Cost Optimization Tips

### Compute Savings Plans
- Purchase 1-year Compute Savings Plan for control plane instances
- Target 60-70% commitment for predictable savings
- Use Spot instances for all worker nodes

### Instance Selection
- **Control Plane**: t3.medium (minimum), t3.large (recommended)
- **Worker Nodes**: Mix of t3, m5, c5 families for flexibility
- **Storage**: gp3 volumes for better price/performance

### Scaling Strategy
```yaml
# In NodePool spec
limits:
  cpu: 1000      # Adjust based on workload needs
  memory: 1000Gi

disruption:
  consolidateAfter: 30s    # Quick scale-down
  expireAfter: 2160h       # 90-day node lifecycle
```

## Troubleshooting

### Common Issues

1. **Karpenter not provisioning nodes**
   ```bash
   kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter
   ```

2. **Worker nodes not joining cluster**
   ```bash
   # Check security groups and IAM roles
   kubectl get events --sort-by='.lastTimestamp'
   ```

3. **Spot interruptions**
   ```bash
   # Check node events
   kubectl describe node <node-name>
   ```

### Useful Commands

```bash
# Monitor Karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Check node provisioning
kubectl get events --field-selector reason=ProvisioningSucceeded

# View node costs (if metrics enabled)
kubectl top nodes

# Scale test workload
kubectl scale deployment test-spot-workload --replicas=10
```

## Cleanup

```bash
# Delete workloads first
kubectl delete -f test-workload.yaml

# Wait for nodes to terminate
kubectl get nodes -w

# Destroy infrastructure
cd infrastructure
terraform destroy
```

## Security Considerations

1. **Restrict SSH access** in `terraform.tfvars`
2. **Use IAM roles** instead of access keys
3. **Enable EBS encryption** (already configured)
4. **Regular security updates** on control plane
5. **Network policies** for pod-to-pod communication

## Next Steps

- **CI/CD Integration**: Connect with GitHub Actions or GitLab CI
- **Service Mesh**: Install Istio or Linkerd for advanced networking
- **Observability**: Add Prometheus, Grafana, and Jaeger
- **Backup Strategy**: Implement etcd backup automation
