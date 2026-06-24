# EKS-D-Xpress Cost Estimation

## Monthly Cost Breakdown (per team member)

### Control Plane (Always Running)
| Component | Instance Type | Hours/Month | On-Demand Price | With Savings Plan | Monthly Cost |
|-----------|---------------|-------------|-----------------|-------------------|--------------|
| Control Plane | m6g.large | 744 | $0.077/hr | $0.055/hr (29% off) | ~$41 |
| Control Plane | m6g.xlarge | 744 | $0.154/hr | $0.110/hr (29% off) | ~$82 |

### Storage (Always Running)
| Component | Size | Type | Monthly Cost |
|-----------|------|------|--------------|
| Root Volume | 50 GB | gp3 | ~$4.00 |
| etcd Volume | 20 GB | gp3 | ~$1.60 |
| **Total Storage** | | | **~$5.60** |

### Worker Nodes (Spot - Pay Only When Running)
| Workload | Instance Type | Spot Price | Hours Used | Monthly Cost |
|----------|---------------|------------|------------|--------------|
| Development | t3.medium | ~$0.0125/hr | 40 hrs | ~$0.50 |
| Testing | m5.large | ~$0.0288/hr | 80 hrs | ~$2.30 |
| Load Testing | c5.xlarge | ~$0.0510/hr | 20 hrs | ~$1.02 |

### Networking
| Component | Monthly Cost |
|-----------|--------------|
| NAT Gateway | ~$32.40 |
| Data Transfer | ~$2-5 |
| **Total Networking** | **~$35** |

## Total Monthly Cost Estimates

### Realistic Usage Scenarios (m6g.xlarge)

#### Scenario 1: Full Development Workday (8 hours/day)
- **Control Plane**: 176 hrs/month × $0.154/hr = $27.10
- **With Savings Plan**: 176 hrs/month × $0.110/hr = $19.36
- **Storage**: $5.60 (always running)
- **Networking**: $35.00 (shared)
- **Worker Nodes**: $10-25 (Spot, as needed)
- **Total**: **$69-85/month per developer** (vs. $132-142 full-time)

#### Scenario 2: Business Hours Only (9-5, weekdays)
- **Control Plane**: 160 hrs/month × $0.110/hr = $17.60
- **Storage**: $5.60
- **Networking**: $35.00 (shared)
- **Worker Nodes**: $5-15 (limited usage)
- **Total**: **$63-73/month per developer** (vs. $132-142 full-time)

#### Scenario 3: Spot + Hibernation (Ultimate Savings)
- **Control Plane**: Spot pricing (~70% off) + hibernation
- **Estimated**: 160 hrs/month × $0.046/hr = $7.36
- **Storage**: $5.60
- **Networking**: $35.00 (shared)
- **Worker Nodes**: $5-15 (Spot)
- **Total**: **$52-62/month per developer** (vs. $132-142 full-time)

## Cost Optimization Strategies

### 1. Hibernation & Scheduling (Major Savings)
```bash
# Control plane usage patterns
Full-time (744 hrs/month): $82/month (m6g.xlarge)
8 hours/day (176 hrs/month): $19.50/month (74% savings)
Business hours only (160 hrs/month): $17.70/month (78% savings)
```

**Implementation Options:**
- **Manual**: Stop/start instances via AWS Console or CLI
- **Scheduled**: CloudWatch Events + Lambda for auto start/stop
- **Hibernation**: EBS-backed hibernation for instant resume
- **Spot + Hibernation**: Additional 60-90% savings on compute

### 2. Compute Savings Plans
```bash
# 1-year commitment examples
t3.medium: $0.0416 → $0.0270 (35% savings)
t3.large:  $0.0832 → $0.0541 (35% savings)
```

### 2. Spot Instance Savings
```bash
# Typical spot discounts
t3.medium: $0.0416 → $0.0125 (70% savings)
m5.large:  $0.0960 → $0.0288 (70% savings)
c5.xlarge: $0.1700 → $0.0510 (70% savings)
```

### 3. Shared Infrastructure
- **Shared NAT Gateway**: Split $32.40 across team members
- **Shared VPC**: Reduce networking costs per person
- **Resource Tagging**: Track individual usage

### 4. Auto-Scaling Configuration
```yaml
# Aggressive scale-down for cost savings
disruption:
  consolidateAfter: 30s    # Quick consolidation
  expireAfter: 2160h       # 90-day max lifetime

limits:
  cpu: 100                 # Limit max resources
  memory: 100Gi
```

## Team Cost Scenarios

### 5-Person Team (8-hour workdays)
| Scenario | Individual Cost | Team Total | Annual Savings vs. Full-Time |
|----------|----------------|------------|------------------------------|
| Business Hours | $69/month | $345/month | $4,680/year |
| Spot + Hibernation | $57/month | $285/month | $6,300/year |

### 10-Person Team (8-hour workdays)
| Scenario | Individual Cost | Team Total | Annual Savings vs. Full-Time |
|----------|----------------|------------|------------------------------|
| Business Hours | $69/month | $690/month | $9,360/year |
| Spot + Hibernation | $57/month | $570/month | $12,600/year |

## Comparison with Alternatives

## Comparison with Alternatives

### vs. Managed EKS
| Component | EKS-D (per cluster) | Managed EKS | Savings |
|-----------|-------------------|-------------|---------|
| Control Plane | $41-82/month | $73/month | Break-even to $32/month |
| Worker Nodes | Same (Spot) | Same (Spot) | $0 |
| **Total Savings** | | | **Break-even to 44% savings** |

### Key Advantages Over Managed EKS
- **Isolation**: Dedicated cluster per team member - no resource contention
- **Full Karpenter**: Complete Karpenter v1 integration with NodePools
- **No API Limits**: No EKS API server throttling
- **Complete Control**: Customize control plane, etcd, scheduler settings
- **Better Performance**: m6g.xlarge handles cert-manager, KEDA, operators smoothly
- **Use Case 1 - CI/CD**: Instant isolated clusters per PR/branch for integration testing
- **Use Case 2 - Development**: Safe environment for CRD/operator development without affecting shared clusters
- **Use Case 3 - Complex Workloads**: Run cert-manager, KEDA, Istio, ArgoCD without resource conflicts

### Additional Benefits with m6g.xlarge
- **Cert-Manager**: Handles certificate lifecycle without CPU throttling
- **KEDA**: Smooth autoscaling decisions with adequate resources
- **Operators**: Multiple operators (Prometheus, Grafana, ArgoCD) run efficiently
- **Development Velocity**: No waiting for shared cluster resources
- **Debugging**: Direct etcd access for troubleshooting complex issues

### When Managed EKS Makes Sense
- Need cross-team shared cluster
- Want AWS-managed upgrades
- Prefer less operational overhead

### When EKS-D Makes Sense
- Individual team environments needed
- Cost optimization priority
- Learning Kubernetes internals
- CI/CD pipeline testing
- CRD/operator development

### vs. Local Development
| Component | EKS-D | Local (Docker Desktop) | Trade-offs |
|-----------|-------|----------------------|------------|
| Cost | $65-90/month | $0 | Cloud integration vs. free |
| AWS Integration | Full | Limited | Native vs. simulated |
| Scalability | Unlimited | Limited by laptop | Real vs. constrained |

## Budget Planning

### Monthly Budget per Team Member (Realistic Usage)
- **Business Hours**: $69/month (8 hours/day)
- **Spot + Hibernation**: $57/month (ultimate optimization)
- **Full-Time**: $132/month (always-on for CI/CD)

### Annual Budget (10-person team)
- **Business Hours**: $8,280/year
- **Spot + Hibernation**: $6,840/year  
- **Full-Time**: $15,840/year

## Cost Monitoring

### CloudWatch Billing Alerts
```bash
# Set up billing alerts for each team member
aws cloudwatch put-metric-alarm \
  --alarm-name "EKS-D-Monthly-Cost-Alert" \
  --alarm-description "Alert when monthly cost exceeds $100" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold
```

### Cost Allocation Tags
```bash
# Tag EC2 instances for cost tracking
aws ec2 create-tags --resources <instance-id> --tags \
  Key=Team,Value=ECP \
  Key=Owner,Value=<team-member> \
  Key=Environment,Value=development \
  Key=Project,Value=eks-d-cluster
```

## Use Cases

### 1. Instant EKS Cluster for CI/CD
- Spin up isolated EKS-D clusters per PR/branch for integration testing
- Each developer gets dedicated test environment without waiting for shared cluster
- Parallel test execution - no queueing or resource contention
- Teardown when done - pay only for actual test runtime

### 2. EKS Development (CRD/Operator Development)
- Deploy and test cluster-wide resources (CRDs, webhooks, operators)
- No pollution of shared development clusters
- Safe experimentation with admission controllers, API servers
- Direct access to control plane for debugging etcd, scheduler, controller-manager

## ROI Analysis

### Development Velocity
- **Setup Time**: 2-3 hours vs. days for manual setup
- **Consistency**: Identical environments across team
- **AWS Integration**: Native vs. simulated locally

### Learning Value
- **Kubernetes Operations**: Real cluster management
- **AWS Services**: Hands-on experience with EC2, VPC, IAM
- **Cost Optimization**: Spot instances, Savings Plans

### Production Readiness
- **Skills Transfer**: Direct application to production
- **Architecture Patterns**: Scalable, cloud-native designs
- **Operational Experience**: Monitoring, troubleshooting, scaling
