# Migration Plan: Terraform → AWS-Native (CloudFormation + SSM + Lambda)

## Motivation

- Eliminate Terraform state management (S3 bucket, locking, provider versions)
- Single toolchain: CloudFormation/SAM for infra, Lambda for tenant lifecycle
- SSM Parameter Store as the shared metadata layer between components
- Simpler onboarding — no external tools required

## Target Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Deployment Flow                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. deploy-shared-infra.sh                               │
│     └── aws cloudformation deploy (shared VPC stack)     │
│         └── Outputs written to SSM Parameter Store       │
│                                                          │
│  2. build-control-plane-ami.sh                           │
│     └── Packer builds AMI                                │
│         └── AMI ID written to SSM (already exists)       │
│                                                          │
│  3. Tenant Provisioning (Lambda)                         │
│     ├── Reads shared infra from SSM                      │
│     ├── Creates tenant resources (EC2, IAM, SG, SQS)    │
│     └── Writes tenant metadata to SSM                    │
│                                                          │
│  4. Tenant Deprovisioning (Lambda)                       │
│     ├── Reads tenant metadata from SSM                   │
│     ├── Terminates resources                             │
│     └── Cleans up SSM parameters                         │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## SSM Parameter Store Schema

### Shared Infrastructure (written by CloudFormation stack)

```
/eks-dx/shared-infra/{region}/vpc-id
/eks-dx/shared-infra/{region}/vpc-cidr
/eks-dx/shared-infra/{region}/public-route-table-id
/eks-dx/shared-infra/{region}/private-route-table-id
/eks-dx/shared-infra/{region}/nat-gateway-id
/eks-dx/shared-infra/{region}/internet-gateway-id
/eks-dx/shared-infra/{region}/availability-zones          # comma-separated
/eks-dx/shared-infra/{region}/launch-template/spot-arm64
/eks-dx/shared-infra/{region}/launch-template/spot-x86_64
/eks-dx/shared-infra/{region}/launch-template/ondemand-arm64
/eks-dx/shared-infra/{region}/launch-template/ondemand-x86_64
```

### AMI Registry (written by AMI builder)

```
/eks-dx/ami/{region}/{k8s-version}/arm64
/eks-dx/ami/{region}/{k8s-version}/x86_64
```

### Tenant Metadata (written by Lambda on provision)

```
/eks-dx/tenants/{tenant-id}/instance-id
/eks-dx/tenants/{tenant-id}/cluster-name
/eks-dx/tenants/{tenant-id}/public-ip
/eks-dx/tenants/{tenant-id}/private-ip
/eks-dx/tenants/{tenant-id}/cluster-endpoint
/eks-dx/tenants/{tenant-id}/subnet-id
/eks-dx/tenants/{tenant-id}/security-group-id
/eks-dx/tenants/{tenant-id}/iam-role-arn
/eks-dx/tenants/{tenant-id}/sqs-queue-url
/eks-dx/tenants/{tenant-id}/arch
/eks-dx/tenants/{tenant-id}/mode                          # spot | ondemand
/eks-dx/tenants/{tenant-id}/created-at
```

## Lambda Lookup Pattern

```python
import boto3

ssm = boto3.client('ssm')

def get_shared_infra(region):
    """Load all shared infra params in one call."""
    response = ssm.get_parameters_by_path(
        Path=f'/eks-dx/shared-infra/{region}/',
        Recursive=True,
        WithDecryption=False
    )
    return {p['Name'].split('/')[-1]: p['Value'] for p in response['Parameters']}

def get_tenant(tenant_id):
    """Load tenant metadata."""
    response = ssm.get_parameters_by_path(
        Path=f'/eks-dx/tenants/{tenant_id}/',
        Recursive=True
    )
    return {p['Name'].split('/')[-1]: p['Value'] for p in response['Parameters']}
```

## CloudFormation Stack Outputs → SSM

The shared infra CloudFormation template writes outputs directly to SSM:

```yaml
Resources:
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr

  # ... other resources ...

  SSMVpcId:
    Type: AWS::SSM::Parameter
    Properties:
      Name: !Sub /eks-dx/shared-infra/${AWS::Region}/vpc-id
      Type: String
      Value: !Ref VPC

  SSMVpcCidr:
    Type: AWS::SSM::Parameter
    Properties:
      Name: !Sub /eks-dx/shared-infra/${AWS::Region}/vpc-cidr
      Type: String
      Value: !Ref VpcCidr
```

## Migration Steps

### Phase 1: SSM as metadata layer (non-breaking)
- Add SSM parameter writes to existing Terraform (`aws_ssm_parameter` resources)
- Update Lambda to read from SSM instead of hardcoded values
- Both Terraform and SSM coexist

### Phase 2: Shared infra → CloudFormation
- Convert `terraform/vpc/` to a CloudFormation template
- Template writes outputs to SSM (replaces Terraform SSM resources)
- Replace `provision-shared-infra.sh` with `aws cloudformation deploy`
- Delete Terraform VPC module

### Phase 3: Remove Terraform entirely
- Lambda handles all tenant provisioning (already built)
- Remove `terraform/main.tf`, `provision-tenant.sh`, `deprovision-tenant.sh`
- Remove Terraform state bucket
- CLI scripts become thin wrappers around Lambda invocations

## What Stays

- **Packer** — AMI builds (no CloudFormation equivalent)
- **Shell scripts** — boot-time cluster setup (runs on EC2, not infra-as-code)
- **SAM** — Lambda deployment (already in eks-dx-control-plane repo)

## Benefits

| Aspect | Terraform (current) | AWS-Native (target) |
|--------|---------------------|---------------------|
| State management | S3 bucket + DynamoDB lock | CloudFormation managed |
| Metadata sharing | Terraform outputs + manual lookup | SSM Parameter Store |
| Tenant lifecycle | `terraform apply/destroy` | Lambda API call |
| Dependencies | terraform binary, providers | AWS CLI only |
| Multi-region | Separate state per region | SSM paths per region |
| Customer extensibility | Edit .tf files | Drop scripts in addons/ |
| Cost | S3 + DynamoDB for state | Free (SSM standard tier) |
