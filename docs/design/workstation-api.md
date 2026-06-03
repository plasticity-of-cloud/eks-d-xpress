# Workstation API — Design Document

## Overview

Replace per-developer Terraform with a self-service API. A Lambda function behind a private API Gateway provisions EKS-DX workstations from a Launch Template.

## Architecture

```
Developer (VPN/VPC)
    │
    ▼
API Gateway (private, HTTPS)
    │
    ▼
Lambda (workstation-lifecycle)
    ├── POST   /workstations        → RunInstances(LaunchTemplate)
    ├── GET    /workstations        → List active workstations
    ├── GET    /workstations/{id}   → Describe workstation
    └── DELETE /workstations/{id}   → TerminateInstances
    │
    ▼
DynamoDB (workstation-registry)
    ├── PK: developer_username
    ├── instance_id, public_ip, arch, mode, created_at, status
    └── TTL for auto-cleanup of terminated records
```

## Launch Template

Defines the complete EC2 configuration. One template per architecture (x86_64, arm64).

| Field | Value |
|-------|-------|
| AMI | Resolved from SSM `/eks-dx/ami/{region}/{k8s-version}/{arch}` |
| Instance type | `m6a.large` (x86_64) / `m6g.large` (arm64) |
| Instance profile | `eks-dx-workstation` (shared role) |
| Security group | `eks-dx-workstation-sg` |
| Key pair | Per-developer (pre-created or generated on first request) |
| User data | Calls `workstation-boot.sh` with developer signum |
| Root volume | 50 GB gp3 |
| Metadata | IMDSv2 required, hop limit 1 |
| Tags | `Name`, `Developer`, `ClusterName`, `Project` |

Spot/On-Demand is NOT baked into the template — it's passed as an `InstanceMarketOptions` override at launch time.

## Lambda Function

**Runtime:** Python 3.12  
**Handler:** `handler.lambda_handler`  
**Timeout:** 30s  
**Memory:** 256 MB

### Endpoints

#### POST /workstations

Request:
```json
{
  "username": "alice",
  "arch": "arm64",
  "mode": "spot",
  "disk_size_gb": 50
}
```

Actions:
1. Check DynamoDB — reject if user already has an active workstation for this arch
2. Resolve AMI from SSM parameter
3. Call `run_instances` with Launch Template + overrides (market options, tags, user data)
4. Write record to DynamoDB
5. Return instance ID

Response:
```json
{
  "instance_id": "i-0abc123",
  "username": "alice",
  "arch": "arm64",
  "mode": "spot",
  "status": "pending"
}
```

#### GET /workstations

Query DynamoDB for all active workstations. Optionally filter by `?username=alice`.

#### GET /workstations/{instance_id}

Describe instance (EC2 API) + DynamoDB record. Returns current state, public IP, uptime.

#### DELETE /workstations/{instance_id}

1. Verify caller owns the instance (or is admin)
2. Terminate instance
3. Update DynamoDB record (status=terminated)

### Error Handling

- 409 Conflict: user already has active workstation for this arch
- 404 Not Found: instance doesn't exist or not owned by caller
- 400 Bad Request: invalid arch, mode, or missing fields

## DynamoDB Table

**Table name:** `eks-dx-workstations`  
**Partition key:** `username` (String)  
**Sort key:** `arch` (String)

| Attribute | Type | Description |
|-----------|------|-------------|
| username | S | Developer IAM username |
| arch | S | x86_64 or arm64 |
| instance_id | S | EC2 instance ID |
| public_ip | S | Assigned public IP |
| mode | S | spot or on_demand |
| status | S | pending / running / terminated |
| created_at | S | ISO 8601 timestamp |
| ttl | N | Auto-delete terminated records after 7 days |

## IAM Roles

### Lambda Execution Role (`eks-dx-api-lambda`)

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:RunInstances",
    "ec2:TerminateInstances",
    "ec2:DescribeInstances",
    "ec2:CreateTags",
    "ssm:GetParameter",
    "dynamodb:PutItem",
    "dynamodb:GetItem",
    "dynamodb:Query",
    "dynamodb:UpdateItem",
    "iam:PassRole"
  ],
  "Resource": "*"
}
```

Scoped down in production:
- `ec2:RunInstances` restricted to Launch Template ARN
- `iam:PassRole` restricted to workstation instance profile role ARN
- DynamoDB restricted to table ARN

### Workstation Instance Role (`eks-dx-workstation`)

Same as current — ECR pull, SSM, SQS (Karpenter), EC2 (Karpenter node management).

## API Gateway

- **Type:** REST API, private (VPC endpoint)
- **Auth:** IAM authorization (SigV4) — callers need `execute-api:Invoke`
- **VPC Endpoint:** Interface endpoint for `execute-api` in the shared VPC
- **Custom domain:** Optional (`workstations.eks-dx.internal`)

## User Data

Minimal — just invokes the pre-baked boot script:

```bash
#!/bin/bash
/opt/eks-d-setup/workstation-boot.sh "${DEVELOPER_USERNAME}"
```

The username is injected by Lambda as a Launch Template override.

## Directory Structure

```
ecp-eks-dx-infra/
├── terraform/
│   ├── main.tf                  # Existing workstation infra (to be replaced)
│   ├── vpc/                     # Shared VPC (unchanged)
│   ├── api/                     # NEW: Lambda + API GW + DynamoDB + Launch Templates
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── lambda.tf
│   └── ...
├── lambda/
│   ├── handler.py               # Lambda function code
│   ├── requirements.txt         # boto3 (bundled in Lambda runtime)
│   └── tests/
│       └── test_handler.py
└── workstation.sh               # CLI wrapper for API calls
```

## CLI Wrapper (`workstation.sh`)

```bash
# Create workstation
./workstation.sh create --arch arm64 --mode spot

# List workstations
./workstation.sh list

# Destroy workstation
./workstation.sh destroy i-0abc123

# Status
./workstation.sh status
```

Uses `aws apigateway` / `curl` with SigV4 signing under the hood.

## Migration Path

1. Deploy API infrastructure (`terraform/api/`)
2. Keep `deploy.sh` working in parallel during transition
3. Migrate developers to `workstation.sh`
4. Remove per-developer Terraform state and `deploy.sh`

## Cost

- Lambda: negligible (few invocations/day)
- API Gateway: ~$1/month
- DynamoDB: on-demand, ~$0/month at this scale
- VPC Endpoint: ~$7/month per AZ
