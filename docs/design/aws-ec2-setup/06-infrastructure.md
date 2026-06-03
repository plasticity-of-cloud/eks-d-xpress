# Infrastructure: Terraform Configuration

## Problem 1: IMDSv2 hop limit blocks containers

The EC2 instance is configured with IMDSv2 required but no hop limit override:

```hcl
metadata_options {
  http_tokens = "required"
  # http_put_response_hop_limit not set — defaults to 1
}
```

The hop limit controls how many network hops an IMDSv2 token request can traverse. With the
default of 1, only processes running directly on the host (in the host network namespace) can
reach the Instance Metadata Service at `169.254.169.254`.

Containers that do not use `hostNetwork: true` cannot reach IMDS. This affects:

- Any pod that calls IMDS for region discovery, instance identity, or credentials
- The AWS SDK's default credential chain (which tries IMDS as a fallback)
- Pods using the EC2 instance profile credentials without an explicit endpoint override

The AWS Cloud Controller Manager and aws-node both use `hostNetwork: true` and are not
affected. However, any application pod that relies on IMDS for credentials or metadata will
fail silently.

EKS sets `http_put_response_hop_limit = 2` on all managed nodes.

**Fix:**

```hcl
metadata_options {
  http_tokens                 = "required"
  http_put_response_hop_limit = 2
}
```

---

## Problem 2: Security group missing intra-cluster rules

The workstation security group only allows inbound SSH:

```hcl
ingress {
  description = "SSH"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = local.allowed_cidrs
}
```

All other inbound traffic is blocked. This prevents:

| Traffic | Port | Required for |
|---------|------|-------------|
| Worker → API server | 6443/TCP | Karpenter worker nodes joining the cluster |
| Control plane → kubelet | 10250/TCP | `kubectl logs`, `kubectl exec`, liveness probes |
| Worker → worker (pod networking) | all | Pod-to-pod communication across nodes |
| Control plane → worker (pod networking) | all | Pod-to-pod communication across nodes |

Without port 6443 open, Karpenter-provisioned worker nodes cannot reach the API server and
will never join the cluster. The nodes will appear in EC2 but never show up in
`kubectl get nodes`.

**Fix — add to `aws_security_group.workstation` in `terraform/main.tf`:**

```hcl
ingress {
  description = "Kubernetes API server"
  from_port   = 6443
  to_port     = 6443
  protocol    = "tcp"
  cidr_blocks = [data.aws_vpc.shared[0].cidr_block]
}

ingress {
  description = "Kubelet API"
  from_port   = 10250
  to_port     = 10250
  protocol    = "tcp"
  cidr_blocks = [data.aws_vpc.shared[0].cidr_block]
}

ingress {
  description = "All traffic within security group (pod networking)"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  self        = true
}
```

The `self = true` rule allows all traffic between instances that share this security group.
Karpenter worker nodes must be configured to use this same security group (or a security group
that has a matching rule) via `EC2NodeClass.spec.securityGroupSelectorTerms`.

---

## Problem 3: Worker node security group not referenced in EC2NodeClass

Karpenter provisions worker nodes with whatever security groups are specified in the
`EC2NodeClass`. If the EC2NodeClass does not reference the control plane's security group,
worker nodes will be in a different security group and the `self = true` rule above will not
apply between control plane and workers.

Ensure the EC2NodeClass `securityGroupSelectorTerms` selects the same security group as the
control plane instance, or a security group that explicitly allows traffic to/from the control
plane security group.

---

## Verification

```bash
# Confirm hop limit is 2
aws ec2 describe-instances \
  --instance-ids $(curl -s http://169.254.169.254/latest/meta-data/instance-id) \
  --query 'Reservations[0].Instances[0].MetadataOptions'

# Test IMDS from a container (should succeed with hop limit 2)
kubectl run imds-test --image=amazonlinux:2 --restart=Never --rm -it \
  -- curl -s -o /dev/null -w "%{http_code}" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
     -X PUT http://169.254.169.254/latest/api/token
# Expected: 200

# Confirm security group rules
aws ec2 describe-security-groups \
  --group-ids <sg-id> \
  --query 'SecurityGroups[0].IpPermissions'
```
