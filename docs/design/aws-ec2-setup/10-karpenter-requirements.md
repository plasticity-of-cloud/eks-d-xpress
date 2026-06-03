# Karpenter Network & IAM Requirements

## VPC Endpoints

### Currently Applied
| Endpoint | Type | Cost | Purpose |
|----------|------|------|---------|
| `com.amazonaws.<region>.s3` | Gateway | **Free** | ECR image layer pulls, EBS snapshots, CloudWatch logs |

### Required for Fully Private Cluster (no internet egress)
All of these are Interface endpoints (~$7/month per AZ each):

| Endpoint | Purpose |
|----------|---------|
| `com.amazonaws.<region>.ec2` | RunInstances, DescribeInstances, CreateFleet, etc. |
| `com.amazonaws.<region>.ecr.api` | Image manifest lookups |
| `com.amazonaws.<region>.ecr.dkr` | Image layer pulls (layers served via S3 endpoint) |
| `com.amazonaws.<region>.sts` | IAM role credential vending (IMDS fallback) |
| `com.amazonaws.<region>.ssm` | Default AMI resolution (`/aws/service/eks/optimized-ami/...`) |
| `com.amazonaws.<region>.sqs` | Spot interruption queue |
| `com.amazonaws.<region>.eks` | DescribeCluster (only if `eksControlPlane=true`) |

> **Note**: There is **no VPC endpoint for the IAM API**. This means:
> - `spec.role` in EC2NodeClass cannot be used (Karpenter can't call `iam:CreateInstanceProfile`)
> - Must use `spec.instanceProfile` with a pre-provisioned instance profile instead
> - See: https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/#private-clusters

> **Note**: There is **no VPC endpoint for the Pricing API** (`api.pricing.us-east-1.amazonaws.com`).
> Karpenter ships a static price list updated at each release. Pricing data goes stale over time.
> Failed pricing requests produce: `ERROR controller.aws.pricing updating on-demand pricing`
> This is non-fatal — Karpenter falls back to the static list.

## IAM Permissions (eks-d-karpenter inline policy)

### Read-only (no conditions)
```
ec2:DescribeAvailabilityZones
ec2:DescribeImages
ec2:DescribeInstances
ec2:DescribeInstanceTypeOfferings
ec2:DescribeInstanceTypes
ec2:DescribeLaunchTemplates
ec2:DescribeSecurityGroups
ec2:DescribeSpotPriceHistory
ec2:DescribeSubnets
ec2:DescribeVolumes
ec2:DescribeVpcs
pricing:GetProducts
ssm:GetParameter
iam:ListInstanceProfiles
iam:GetInstanceProfile
iam:CreateInstanceProfile
iam:DeleteInstanceProfile
iam:AddRoleToInstanceProfile
iam:RemoveRoleFromInstanceProfile
iam:TagInstanceProfile
```

### Mutating EC2 (condition: `aws:RequestTag/kubernetes.io/cluster/<name>=owned`)
```
ec2:RunInstances
ec2:CreateFleet
ec2:CreateLaunchTemplate
ec2:DeleteLaunchTemplate
ec2:TerminateInstances
ec2:CreateTags
```

### Mutating existing resources (condition: `ec2:ResourceTag/kubernetes.io/cluster/<name>=owned`)
```
ec2:TerminateInstances
ec2:DeleteLaunchTemplate
```

### Other
```
iam:PassRole          # Resource: the workstation role ARN only
sqs:DeleteMessage     # Resource: the interruption queue ARN only
sqs:GetQueueAttributes
sqs:GetQueueUrl
sqs:ReceiveMessage
```

## DNS Policy

Karpenter must use `dnsPolicy: Default` (host DNS) on self-managed EKS-D clusters.

**Reason**: CoreDNS external forwarding is broken on EKS-D due to the `loop` plugin
silently disabling the `forward` plugin. `dnsPolicy: Default` bypasses CoreDNS and
uses the node's `/etc/resolv.conf` (VPC DNS at `10.0.0.2`) directly.

This is documented in the official Karpenter docs:
> If DNS won't be running when Karpenter starts up, set `--set dnsPolicy=Default`.

Set via Helm: `--set dnsPolicy=Default`

## SQS Interruption Queue

Must be created before Karpenter starts. Queue name must match `settings.interruptionQueue`.

```bash
aws sqs create-queue \
  --queue-name <cluster-name> \
  --attributes MessageRetentionPeriod=300 \
  --tags "kubernetes.io/cluster/<cluster-name>=owned"
```

Created by Terraform (`aws_sqs_queue.karpenter_interruption` in `terraform/main.tf`).

## EC2NodeClass Requirements

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
spec:
  # Must use instanceProfile, NOT role (IAM has no VPC endpoint)
  instanceProfile: "eks-d-workstation-<signum>"

  # AL2023 EKS-Optimized AMI — same kubelet as EKS-D (EKS-D is the upstream)
  amiSelectorTerms:
    - alias: al2023@v1.35

  # nodeadm NodeConfig for self-managed cluster
  userData: |
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: <cluster-name>
        apiServerEndpoint: https://<control-plane-ip>:6443
        certificateAuthority: <base64-ca-cert>
        cidr: 10.96.0.0/12
    --//--
```

## Node Authentication (aws-iam-authenticator)

Worker nodes authenticate via IAM role (not bootstrap tokens). Requires:

1. `aws-iam-authenticator` static pod on control plane (configured in `06-install-eks-d.sh`)
2. API server started with `--authentication-token-webhook-config-file`
3. IAM role mapped to `system:nodes` group in authenticator config

The worker node IAM role (`eks-d-workstation-<signum>`) is reused for both the
control plane EC2 instance and Karpenter-provisioned worker nodes.
