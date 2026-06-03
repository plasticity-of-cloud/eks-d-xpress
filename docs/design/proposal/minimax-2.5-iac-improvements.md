# IaC Architecture Review: EKS-DX Infrastructure

**Date:** 2026-05-05  
**Reviewer:** Chief IaC Architect  
**Scope:** Terraform (main, vpc, ami-builder) + Shell scripts (deploy, destroy, eks-d-setup, node-pools)

---

## Executive Summary

The codebase is well-structured with clear separation of concerns (VPC, workstation, AMI builder). Several improvements can enhance security, resilience, and operational maintainability.

---

## Critical Findings

### 1. Hardcoded AWS Region in Karpenter Installation
**File:** `eks-d-setup/11-install-karpenter.sh`  
**Issue:** Line `export AWS_REGION=us-east-1` hardcodes region, ignoring deployment region.

```bash
# Current (line ~10)
export AWS_REGION=us-east-1

# Recommended
export AWS_REGION="${AWS_REGION:-$(aws configure get region)}"
```

### 2. IAM Policy Uses Wildcard `Resource = "*"` Extensively
**File:** `terraform/main.tf` (karpenter policy, cloud_provider policy)  
**Issue:** Over-permissive policies violate least-privilege principle.

**Recommendations:**
- Karpenter: Restrict `ec2:Describe*` to specific VPC/subnet ARNs
- Cloud Provider: Limit `ec2:Describe*` to the shared VPC CIDR
- Use `ec2:ResourceTag/kubernetes.io/cluster/${cluster}` conditions consistently

### 3. SQS Queue Policy Missing
**File:** `terraform/main.tf` (`aws_sqs_queue.karpenter_interruption`)  
**Issue:** Karpenter interruption handling requires the queue to accept messages from AWS EC2 Spot service.

```hcl
resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}
```

### 4. VPC Lacks Private Link Endpoints for Common Services
**File:** `terraform/vpc/main.tf`  
**Issue:** Missing endpoints for:
- `ec2` (EC2 API calls)
- `ssm` (SSM parameter access)
- `logs` (CloudWatch Logs)

```hcl
resource "aws_vpc_endpoint" "ec2" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.ec2"
  vpc_endpoint_type = "Interface"
  security_group_ids = [aws_security_group.vpc_endpoints.id]
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type = "Interface"
  security_group_ids = [aws_security_group.vpc_endpoints.id]
}
```

---

## High Priority Improvements

### 5. No State Locking Mechanism
**File:** `terraform/backend.tf` (all modules)  
**Issue:** Multiple developers can concurrently modify state despite `use_lockfile = true`.

**Recommendation:** Use DynamoDB state locking (standard Terraform pattern):

```hcl
# Add to backend config in bootstrap.sh
aws dynamodb create-table \
  --table-name eks-dx-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

```hcl
# Update backend.tf
backend "s3" {
  bucket         = "eks-dx-tfstate-${account_id}"
  key            = "eks-dx/${workstation_name}/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "eks-dx-tfstate-lock"
  use_lockfile   = true
}
```

### 6. No Output for Critical Instance Details
**File:** `terraform/outputs.tf`  
**Issue:** Missing outputs for SSH commands and connection info.

```hcl
output "ssh_command" {
  description = "SSH command to connect to workstation"
  value       = "ssh -i ${var.key_pair_name}.pem ec2-user@${aws_instance.workstation.public_ip}"
}
```

### 7. AMI Builder Lacks Cleanup for Builder Instance
**File:** `ami-builder/main.tf`  
**Issue:** Builder EC2 is never terminated after AMI creation.

```hcl
resource "null_resource" "cleanup_builder" {
  depends_on = [null_resource.create_ami]

  provisioner "local-exec" {
    command = "aws ec2 terminate-instances --instance-ids ${aws_instance.builder.id} --region ${var.aws_region}"
  }
}
```

### 8. Subnet Auto-Discovery Logic Fragile
**File:** `terraform/main.tf` (locals block)  
**Issue:** Regex-based index calculation assumes CIDR pattern `10.0.X.0/24` and skips 0.

```hcl
# Current problematic logic
existing_indices = [
  for s in data.aws_subnets.developer_public.ids : 
  tonumber(regex("10\\.0\\.(\\d+)\\.0/24", data.aws_subnet.existing[s].cidr_block)[0])
  if tonumber(regex("10\\.0\\.(\\d+)\\.0/24", data.aws_subnet.existing[s].cidr_block)[0]) > 0
]
```

**Recommendation:** Use tags for deterministic allocation:
```hcl
locals {
  subnet_index = var.subnet_index != null ? var.subnet_index : 
    max([for s in data.aws_subnets.developer_public.ids : 
      tonumber(lookup(data.aws_subnet.existing[s].tags, "SubnetIndex", "0"))]...)
}
```

---

## Medium Priority Improvements

### 9. Missing Cost Optimization: Spot Instance for Workstation
**File:** `terraform/main.tf` (`aws_instance.workstation`)  
**Issue:** Uses On-Demand by default. For dev workstations, Spot with interruption handling may reduce costs 60-70%.

**Note:** This requires careful evaluation of disruption tolerance.

### 10. No Lifecycle Policies on S3 State Bucket
**File:** `bootstrap.sh`  
**Issue:** Terraform state versions retained indefinitely.

```bash
# Add lifecycle rule
aws s3api put-bucket-lifecycle-configuration \
  --bucket "${BUCKET}" \
  --lifecycle-configuration '{"Rules":[{"ID":"tfstate-expiry","Status":"Enabled","ExpirationInDays":90}]}'
```

### 11. Security Group Allows All Internal Traffic
**File:** `terraform/main.tf` (`aws_security_group.workstation`)

```hcl
ingress {
  description = "All traffic within security group"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  self        = true
}
```

**Recommendation:** Limit to specific pod/CNI ports unless required:
- Kubelet: 10250
- NodePort services: 30000-32767

### 12. No Backup Strategy for etcd Volume
**File:** `eks-d-setup/05-prepare-etcd.sh`  
**Issue:** EBS volume for etcd has no automated snapshots.

**Recommendation:** Add daily snapshot lifecycle:
```hcl
resource "aws_ebs_snapshot" "etcd" {
  count = 3  # Retain last 3 snapshots
  # ...
}
```

---

## Low Priority / Nice-to-Have

### 13. Karpenter Version Hardcoded
**File:** `eks-d-setup/11-install-karpenter.sh`  
**Recommendation:** Externalize to variable or SSM parameter.

### 14. Missing Validation in Shell Scripts
**File:** `deploy.sh`, `destroy.sh`  
**Recommendation:** Add `--validate` or dry-run checks.

### 15. No Terraform fmt/validate in CI
**Recommendation:** Add pre-commit hooks:
```bash
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.83.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: tflint
```

---

## Summary Matrix

| ID | Category | Severity | Complexity |
|----|----------|----------|------------|
| 1  | Security | Critical | Low |
| 2  | Security | Critical | Medium |
| 3  | Reliability | High | Low |
| 4  | Cost/Security | High | Medium |
| 5  | Reliability | High | Low |
| 6  | Operational | High | Low |
| 7  | Operational | High | Low |
| 8  | Reliability | High | Medium |
| 9  | Cost | Medium | Medium |
| 10 | Cost | Medium | Low |
| 11 | Security | Medium | Low |
| 12 | Reliability | Medium | Medium |
| 13 | Operational | Low | Low |
| 14 | Operational | Low | Low |
| 15 | Operational | Low | Medium |

---

## Next Steps

1. **Immediate:** Fix items 1-3 (hardcoded region, IAM wildcards, SQS policy)
2. **Sprint 1:** Items 4-8 (VPC endpoints, state locking, outputs, cleanup, subnet logic)
3. **Sprint 2:** Items 9-12 (cost optimization, lifecycle, security group tightening, backup)
4. **Backlog:** Items 13-15
