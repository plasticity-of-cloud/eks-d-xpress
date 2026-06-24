# Shared Infrastructure — Terraform to CDK (Java) Migration

> ⚠️ **Historical.** This migration has been completed in the `eks-d-xpress-infra` repository
> (`EksDxSharedInfraStack`). Terraform is gone. This document is kept for reference.
> Note: SSM paths below use `/eks-dx/` — the deployed prefix is `/eks-d-xpress/`.

## Overview

The shared VPC infrastructure currently lives in `terraform/vpc/` and is deployed via
`provision-shared-infra.sh`. This document describes the migration to AWS CDK (Java).

The shared infra is **region-scoped, deployed once per region**, and contains no
tenant-specific resources. It is a prerequisite for tenant provisioning.

---

## What Is Being Migrated

All resources in `terraform/vpc/main.tf`:

| Resource | Terraform | CDK construct |
|---|---|---|
| VPC (`10.0.0.0/16`) | `aws_vpc` | `ec2.Vpc` |
| Internet Gateway | `aws_internet_gateway` | implicit in `ec2.Vpc` |
| NAT subnet (`10.0.0.0/24`) | `aws_subnet` | `ec2.Subnet` |
| NAT Gateway + EIP | `aws_nat_gateway` + `aws_eip` | implicit in `ec2.Vpc` or `ec2.NatGateway` |
| Public route table + default route | `aws_route_table` | implicit in `ec2.Vpc` |
| Private route table + NAT route | `aws_route_table` | implicit in `ec2.Vpc` |
| VPC Flow Logs (CloudWatch, 7d retention) | `aws_flow_log` | `ec2.FlowLog` |
| ECR pull-through cache (public.ecr.aws, registry.k8s.io) | `aws_ecr_pull_through_cache_rule` | `ecr.CfnPullThroughCacheRule` |
| S3 Gateway Endpoint | `aws_vpc_endpoint` | `ec2.GatewayVpcEndpoint` |
| Shared Launch Templates (4: spot/ondemand × arm64/x86_64) | `aws_launch_template` | `ec2.LaunchTemplate` |
| SSM parameters for LT IDs | `aws_ssm_parameter` | `ssm.StringParameter` |

---

## CDK Stack Design

### Stack: `EksDxSharedInfraStack`

Single stack, one per region. Parameterised via CDK context or environment variables.

**Context keys:**

| Key | Default | Description |
|---|---|---|
| `projectName` | `eks-dx` | Resource name prefix |
| `instanceTypeArm64` | `m7g.large` | Default arm64 control plane instance type |
| `instanceTypeX86_64` | `m7i.large` | Default x86_64 control plane instance type |
| `diskSizeGb` | `20` | Root volume size for launch templates |

---

## Resource-by-Resource Notes

### VPC

CDK's `ec2.Vpc` creates IGW, route tables, and NAT gateway automatically when
`natGateways: 1` is set. Use `subnetConfiguration` to define the NAT subnet explicitly.

CIDR must be `10.0.0.0/16` to match the existing tenant subnet allocation scheme
(`10.0.<index>.0/24` for public, `10.0.<100+index>.0/24` for private).

The VPC must be tagged `Name: eks-dx-shared-vpc` — tenant Terraform discovers it by
this tag via `data "aws_vpc"`.

### Route Tables

Tenant Terraform looks up route tables by name tag:
- `eks-dx-public-rt`
- `eks-dx-private-rt`

These tags must be preserved exactly in CDK.

### VPC Flow Logs

The existing log group `/aws/vpc/<region>/eks-dx-flow-logs` may already exist with
retained logs. On first CDK deploy, import it using a CDK custom resource or
`CfnInclude`, or simply let CDK create it (CloudFormation will fail if it already
exists — use `RemovalPolicy.RETAIN` and handle the import).

Retention: 7 days.

### ECR Pull-Through Cache

Use `ecr.CfnPullThroughCacheRule` (L1) — no L2 construct exists yet.

Two rules:
- `public-ecr` → `public.ecr.aws`
- `registry-k8s-io` → `registry.k8s.io`

These are account-scoped (not VPC-scoped), so they only need to be created once
per account, not per region. Consider a separate stack or a condition guard.

### S3 Gateway Endpoint

Use `ec2.GatewayVpcEndpoint`. Associate with both public and private route tables.
This is free and required for ECR image pulls, EBS CSI, and Karpenter pricing data
to avoid NAT charges.

### Launch Templates

Four templates: `{spot,ondemand} × {arm64,x86_64}`.

Key properties to preserve:
- `httpTokens: required` (IMDSv2)
- `httpPutResponseHopLimit: 2`
- Root volume: gp3, encrypted, `deleteOnTermination: true`, size from context
- etcd volume: `/dev/sdf`, gp3, 20 GB, encrypted, `deleteOnTermination: true`
- Spot templates: `instanceInterruptionBehavior: hibernate`, `hibernationOptions: configured: true`
- No `imageId` — AMI is passed as override at `RunInstances` time by the Lambda

Tag specifications on `instance` and `volume` resources must be preserved (Karpenter
reads instance tags).

### SSM Parameters

After creating each launch template, write its ID to SSM:

```
/eks-dx/launch-template/arm64/spot
/eks-dx/launch-template/arm64/ondemand
/eks-dx/launch-template/x86_64/spot
/eks-dx/launch-template/x86_64/ondemand
```

Use `ssm.StringParameter` with `parameterName` set explicitly.

---

## Migration Strategy

### Phase 1 — CDK stack alongside Terraform (no cutover yet)

1. Create CDK app in `eks-dx-control-plane` (or a new `ecp-eks-dx-shared-infra-cdk` module).
2. Implement `EksDxSharedInfraStack` covering all resources above.
3. Deploy to a **fresh region** (not the region where Terraform state exists) to validate.
4. Verify SSM parameters are written correctly and tenant provisioning works end-to-end.

### Phase 2 — Import existing resources into CDK

For the active region, existing resources must be imported into the CDK stack rather
than recreated (to avoid VPC ID changes breaking all tenant subnets).

Use `cdk import` (CDK v2.100+) to import:
- VPC, IGW, subnets, route tables, NAT GW, EIP
- Flow log, log group, IAM role
- ECR pull-through cache rules
- S3 endpoint
- Launch templates
- SSM parameters

### Phase 3 — Remove Terraform

Once CDK manages all resources and state is confirmed clean:
1. Remove `terraform/vpc/` directory.
2. Replace `provision-shared-infra.sh` with a CDK deploy wrapper script.
3. Update `deprovision-shared-infra.sh` to call `cdk destroy`.

---

## Deployment Script (target)

Replace `provision-shared-infra.sh` with:

```bash
#!/bin/bash
set -euo pipefail
REGION="${1:-us-east-1}"
cdk deploy EksDxSharedInfraStack \
  --context projectName=eks-dx \
  --region "${REGION}" \
  --require-approval never
```

---

## What Does NOT Move to CDK

The following remain outside this stack:

- **Tenant resources** (IAM role, SG, subnets, SQS, EC2) — migrating to Lambda in `eks-dx-control-plane`
- **AMI SSM parameters** (`/eks-dx/ami/<arch>/<k8s_version>`) — written by Packer, not infrastructure
- **NodePool Helm chart** — applied on the EC2 instance at boot time
- **SSM Documents** (`eks-dx-status-*`, `eks-dx-bootstrap-*`) — currently in `terraform/ssm-documents.tf`, can move to CDK separately or to `eks-dx-control-plane`
