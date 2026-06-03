# AMI Build Pipeline — AWS Setup Guide

## Overview

The AMI build pipeline uses GitHub Actions OIDC to assume an AWS IAM role
(no long-lived credentials), builds AMIs with Packer, signs each AMI's
attestation with KMS, and generates an SPDX SBOM of the installed filesystem.

```
GitHub Actions (OIDC)
  └─ assume eks-dx-packer-ci (IAM role)
       ├─ Packer builds EC2 builder instance
       │    └─ temporary instance profile (ECR pull-through access)
       ├─ syft generates SBOM → downloaded as artifact
       ├─ AMI ID written to SSM /eks-d-xpress/infra/ami/{arch}/{version}
       └─ KMS signs attestation → signature in SSM + AMI tag
```

## One-time AWS setup

Run once per AWS account. Requires `AdministratorAccess` or equivalent.

```bash
export AWS_REGION=us-east-1
export GITHUB_ORG=plasticity-of-cloud
export GITHUB_REPO=eks-d-xpress   # optional, defaults to eks-d-xpress

./ami-builder/setup-iam.sh
```

The script creates:

| Resource | Name/Path |
|---|---|
| IAM OIDC provider | `token.actions.githubusercontent.com` |
| IAM role | `eks-dx-packer-ci` |
| KMS signing key | `alias/eks-d-xpress-ami-signing` (RSA 4096, SIGN_VERIFY) |
| SSM parameter | `/eks-d-xpress/infra/kms/ami-signing-key-arn` |

At the end the script prints the values to add to GitHub:

| GitHub setting | Value |
|---|---|
| Variable `AWS_REGION` | e.g. `us-east-1` |
| Secret `AWS_PACKER_ROLE_ARN` | `arn:aws:iam::ACCOUNT:role/eks-dx-packer-ci` |

## IAM least-privilege model

### GitHub Actions role (`eks-dx-packer-ci`)

Packer requires broad EC2 permissions by design (it creates instances, volumes,
snapshots, security groups, key pairs). The role is scoped to the minimum
Packer documents as required:

- **EC2**: instance lifecycle, AMI creation/registration, security groups,
  key pairs, snapshots, volumes, tags
- **IAM**: scoped to `packer-*` resource prefix only — Packer creates a
  temporary instance profile for the builder instance; no other IAM paths
  are accessible
- **SSM**: write/read restricted to `parameter/eks-d-xpress/*`
- **KMS sign**: restricted to keys tagged `Usage=eks-d-xpress-ami-signing`

The trust policy restricts `AssumeRoleWithWebIdentity` to:
- Audience: `sts.amazonaws.com`  
- Subject: `repo:plasticity-of-cloud/eks-d-xpress:*` (any branch/tag/PR)

Narrow to a specific branch for production accounts:
```json
"StringEquals": {
  "token.actions.githubusercontent.com:sub":
    "repo:plasticity-of-cloud/eks-d-xpress:ref:refs/heads/main"
}
```

### Builder instance profile (inline in `eks-dx.pkr.hcl`)

The temporary EC2 instance that packer SSHes into only receives:
- ECR pull-through cache access (read-only)
- `ssm:GetParameter` for discovering component versions

It has no write access and no IAM permissions.

## AMI digital signing

AWS does not have native AMI signing (unlike container image signing). The
pipeline implements it via KMS attestation:

1. After packer builds the AMI, `sign-ami.sh` creates a JSON attestation:
   ```json
   {
     "ami_id":             "ami-0abc123...",
     "arch":               "arm64",
     "kubernetes_version": "1.35",
     "ami_version":        "20260603-1445",
     "timestamp":          "2026-06-03T14:45:00Z"
   }
   ```

2. Signs it with `aws kms sign` (RSA 4096, RSASSA_PKCS1_V1_5_SHA_256)

3. Stores the base64 signature in SSM:
   ```
   /eks-d-xpress/infra/ami/{arch}/{k8s_version}/signature
   ```

4. Tags the AMI:
   ```
   Signed=true
   SigningKeyArn=arn:aws:kms:...
   ```

### Verifying an AMI before use

```bash
AMI_ID=ami-0abc123
ARCH=arm64
K8S_VERSION=1.35
REGION=us-east-1

# 1. Reconstruct the attestation (must match exactly what was signed)
ATTESTATION=$(aws ec2 describe-images --region "$REGION" \
  --image-ids "$AMI_ID" \
  --query 'Images[0].{ami_id:ImageId,arch:Tags[?Key==`Name`]|[0].Value}' \
  --output json)
# Use the values from the AMI's own tags/SSM to rebuild the attestation JSON

# 2. Retrieve signature and key ARN
SIG=$(aws ssm get-parameter --region "$REGION" \
  --name "/eks-d-xpress/infra/ami/${ARCH}/${K8S_VERSION}/signature" \
  --query 'Parameter.Value' --output text)

KEY_ARN=$(aws ec2 describe-images --region "$REGION" \
  --image-ids "$AMI_ID" \
  --query "Images[0].Tags[?Key=='SigningKeyArn'].Value" --output text)

# 3. Verify
echo -n "$ATTESTATION" > /tmp/attestation.json
echo "$SIG" | base64 -d > /tmp/signature.bin
aws kms verify --region "$REGION" \
  --key-id "$KEY_ARN" \
  --message-type RAW \
  --signing-algorithm RSASSA_PKCS1_V1_5_SHA_256 \
  --message fileb:///tmp/attestation.json \
  --signature fileb:///tmp/signature.bin \
  --query 'SignatureValid'
# Returns: true
```

## SBOM

During the packer build, [syft](https://github.com/anchore/syft) scans the
full installed filesystem and outputs an SPDX 2.3 JSON SBOM. It is:

- Downloaded from the builder instance by packer as `sbom-{arch}-{version}.spdx.json`
- Uploaded as a GitHub Actions artifact (90-day retention)
- Attached to GitHub releases as a downloadable asset
- Checksummed in `checksums.txt`

The SBOM captures all RPM packages, Go binaries, Python packages, and other
software installed on the AMI at build time.

## Running locally

```bash
# One-time setup (if not done)
AWS_REGION=us-east-1 GITHUB_ORG=plasticity-of-cloud ./ami-builder/setup-iam.sh

# Build + sign
ARCH=arm64 AWS_REGION=us-east-1 ./ami-builder/build-golden-amis.sh

# Sign only (after a build)
AMI_VERSION=20260603-1445 AWS_REGION=us-east-1 \
  make -C ami-builder sign
```
