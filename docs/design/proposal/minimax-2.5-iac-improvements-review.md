# Review of minimax-2.5-iac-improvements.md

**Date:** 2026-05-05  
**Reviewer:** Chief IaC Architect (second pass)  
**Verdict:** 8 of 15 items are actionable as-is. 5 contain technical errors that would break the system. 2 are valid but low-value.

---

## Items Approved (implement as proposed)

| ID | Finding | Notes |
|----|---------|-------|
| 1  | Hardcoded region | Valid. Fix: source from `/opt/eks-d/cluster.env` (not `aws configure get region` which may be unset on EC2). |
| 3  | SQS queue policy | Valid. Also add EventBridge rules for `aws.ec2 instance-action` and `aws.ec2 spot-interruption` events. |
| 6  | Missing outputs | Valid, trivial. |
| 8  | Fragile subnet logic | Valid. Tag-based approach is better but needs `coalesce()` fallback for empty list. |
| 13 | Hardcoded Karpenter version | Valid. Move to `/opt/eks-d/versions.env`. |
| 14 | Missing script validation | Valid. |
| 15 | No pre-commit hooks | Valid. |

---

## Items Requiring Correction

### Item 2: IAM Wildcard Policies — PARTIALLY INCORRECT

`ec2:Describe*` actions **do not support resource-level permissions** in AWS IAM. You cannot restrict them to specific VPC/subnet ARNs. The only valid restriction is via condition keys like `ec2:Region`.

The existing code already correctly applies tag-based conditions on **mutating** actions (`RunInstances`, `TerminateInstances`, `CreateVolume`, etc.). The read-only `Describe*` statements with `Resource: "*"` are the AWS-recommended pattern.

**Verdict:** No change needed for Describe actions. The proposal's recommendation is technically impossible.

---

### Item 5: State Locking — INCORRECT (already solved)

The backend uses `use_lockfile = true` which is Terraform 1.10+'s native S3 locking via conditional writes (S3 `If-None-Match` header). This does NOT require DynamoDB.

```hcl
backend "s3" {
  use_lockfile = true  # ← This IS the lock mechanism
}
```

Adding DynamoDB is redundant and adds unnecessary infrastructure cost.

**Verdict:** No change needed. The proposal misidentifies a non-issue.

---

### Item 7: AMI Builder Cleanup — WRONG APPROACH

Using `null_resource` + `local-exec` to terminate an instance that Terraform manages causes **state drift**. Terraform will still track the instance as existing.

**Correct approach:** The `build.sh` wrapper script should run `terraform destroy` after AMI creation:

```bash
# In build.sh (after AMI is created and stored in SSM)
terraform -chdir=ami-builder destroy -auto-approve
```

**Verdict:** Valid concern, wrong fix. Use `terraform destroy` in the wrapper script.

---

### Item 9: Spot for Workstation — CONDITIONALLY APPROVE (with hibernation)

~~The control plane EC2 runs etcd + API server. A Spot interruption would kill etcd → permanent data loss.~~

**Correction:** AWS Spot hibernation preserves full memory state to the encrypted root EBS volume on interruption. On capacity restoration, the instance resumes exactly where it left off — etcd, API server, and all processes intact.

**Prerequisites for enabling:**
```hcl
resource "aws_instance" "workstation" {
  # ...
  hibernation = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.disk_size_gb
    encrypted             = true          # REQUIRED for hibernation
    delete_on_termination = true
  }
}
```

**Trade-offs:**
- Cluster unavailable during hibernation (minutes to hours depending on capacity)
- Worker nodes lose API server connectivity → Karpenter re-provisions after resume
- 60-70% cost reduction on control plane instance

**Verdict:** Viable for dev workstations. Add `hibernation = true` + encrypted root volume. Acceptable trade-off: temporary unavailability vs significant cost savings.

---

### Item 10: S3 Lifecycle — DANGEROUS AS WRITTEN

The proposed rule expires **all objects** after 90 days:
```bash
"ExpirationInDays":90
```

This would **delete active Terraform state files**, making it impossible to manage or destroy workstations older than 90 days.

**Correct approach:** Expire only non-current versions:
```bash
aws s3api put-bucket-lifecycle-configuration --bucket "${BUCKET}" \
  --lifecycle-configuration '{
    "Rules":[{
      "ID":"expire-old-versions",
      "Status":"Enabled",
      "NoncurrentVersionExpiration":{"NoncurrentDays":30},
      "Filter":{"Prefix":""}
    }]
  }'
```

**Verdict:** Valid intent, dangerous implementation. Fix the rule to target non-current versions only.

---

### Item 11: Security Group Tightening — IMPRACTICAL

VPC CNI pod networking requires unrestricted traffic between nodes in the same security group. Pods communicate on arbitrary ports; restricting to kubelet+NodePort would break:
- Pod-to-pod communication across nodes
- CoreDNS resolution (UDP 53 between pods)
- Any service using ClusterIP

The `self = true` rule is the standard pattern for Kubernetes node security groups.

**Verdict:** No change. The current configuration is correct for VPC CNI.

---

### Item 12: etcd Backup — WRONG RESOURCE TYPE

`aws_ebs_snapshot` is a point-in-time resource, not a lifecycle policy. The correct Terraform resource for automated recurring snapshots is:

```hcl
resource "aws_dlm_lifecycle_policy" "etcd_backup" {
  description        = "EKS-DX etcd daily backup"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Name = "etcd-data" }

    schedule {
      name = "daily"
      create_rule { interval = 24; interval_unit = "HOURS" }
      retain_rule { count = 3 }
    }
  }
}
```

**Verdict:** Valid concern, wrong implementation. Use DLM lifecycle policy.

---

### Item 4: VPC Interface Endpoints — DEPRIORITIZE

Interface endpoints cost **~$7.20/month each** + $0.01/GB data processing. For 3 endpoints across a dev environment:
- Monthly cost: ~$22/month fixed + data charges
- Benefit: Marginal (NAT gateway already provides connectivity; workstations have public IPs)

The S3 Gateway endpoint (already present, free) is the high-value item. Interface endpoints are justified only if:
- Workstations move to private subnets (no public IP)
- NAT gateway is removed for cost savings

**Verdict:** Valid but low ROI for current architecture. Defer unless moving to private-only networking.

---

## Revised Priority Matrix

| ID | Original Severity | Revised Verdict | Action |
|----|-------------------|-----------------|--------|
| 1  | Critical | ✅ Approve | Fix region sourcing |
| 2  | Critical | ❌ Incorrect | No change needed |
| 3  | High | ✅ Approve (expand) | Add SQS policy + EventBridge rules |
| 4  | High | ⏸️ Defer | Low ROI for current architecture |
| 5  | High | ❌ Incorrect | Already solved by `use_lockfile` |
| 6  | High | ✅ Approve | Add outputs |
| 7  | High | ⚠️ Fix approach | Use `terraform destroy` in build.sh |
| 8  | High | ✅ Approve (fix) | Tag-based with fallback |
| 9  | Medium | ✅ Approve (with hibernation) | Add `hibernation=true` + encrypted root |
| 10 | Medium | ⚠️ Fix rule | NoncurrentVersionExpiration only |
| 11 | Medium | ❌ Incorrect | Required for VPC CNI |
| 12 | Medium | ⚠️ Fix resource | Use DLM, not aws_ebs_snapshot |
| 13 | Low | ✅ Approve | Externalize version |
| 14 | Low | ✅ Approve | Add validation |
| 15 | Low | ✅ Approve | Add pre-commit |

---

## Revised Implementation Plan

**Immediate (this week):**
1. Fix hardcoded region in `11-install-karpenter.sh` (item 1)
2. Add SQS queue policy + EventBridge rules for Spot interruption (item 3)
3. Add `terraform destroy` to `build.sh` after AMI creation (item 7)

**Next sprint:**
4. Tag-based subnet allocation with fallback (item 8)
5. DLM lifecycle policy for etcd volume (item 12)
6. S3 non-current version expiration (item 10)
7. Terraform outputs for SSH command (item 6)

**Backlog:**
8. Externalize Karpenter version (item 13)
9. Script validation / dry-run (item 14)
10. Pre-commit hooks (item 15)

**Future improvement:**
11. Spot with hibernation for control plane (item 9) — requires `hibernation = true` + encrypted root volume; ~60-70% cost savings
