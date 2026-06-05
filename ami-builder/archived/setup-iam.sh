#!/usr/bin/env bash
# setup-iam.sh — One-time AWS IAM setup for the EKS-DX AMI build pipeline.
#
# Creates:
#   - GitHub OIDC provider (idempotent)
#   - Least-privilege IAM role for Packer (eks-dx-packer-ci)
#   - KMS asymmetric signing key for AMI attestations
#   - Stores key ARN in SSM for use by the pipeline
#
# Usage:
#   AWS_REGION=us-east-1 GITHUB_ORG=plasticity-of-cloud ./ami-builder/setup-iam.sh
set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:?set GITHUB_ORG}"
GITHUB_REPO="${GITHUB_REPO:-eks-d-xpress}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"
ROLE_NAME="eks-d-xpress-packer-ci"
KEY_ALIAS="alias/eks-d-xpress-ami-signing"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

echo "==> Account: ${ACCOUNT_ID} | Region: ${AWS_REGION}"

# ── 1. GitHub OIDC provider ────────────────────────────────────────────────
echo "==> Setting up GitHub OIDC provider..."
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" &>/dev/null; then
  THUMBPRINT=$(echo | openssl s_client -connect token.actions.githubusercontent.com:443 2>/dev/null \
    | openssl x509 -fingerprint -sha1 -noout \
    | sed 's/://g' | awk -F= '{print tolower($2)}')
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_PROVIDER}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT}"
  echo "    ✓ OIDC provider created"
else
  echo "    ✓ OIDC provider already exists"
fi

# ── 2. IAM role trust policy ───────────────────────────────────────────────
echo "==> Creating IAM role: ${ROLE_NAME}..."
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "${OIDC_PROVIDER}:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
      }
    }
  }]
}
EOF
)

if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
    --policy-document "${TRUST_POLICY}"
  echo "    ✓ Role trust policy updated"
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "Least-privilege role for EKS-DX Packer AMI builds via GitHub Actions OIDC"
  echo "    ✓ Role created"
fi

ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)

# ── 3. Inline policy ───────────────────────────────────────────────────────
echo "==> Attaching least-privilege policy..."
aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name "eks-d-xpress-packer-build" \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PackerEC2",
      "Effect": "Allow",
      "Action": [
        "ec2:AttachVolume", "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateImage", "ec2:CreateKeyPair", "ec2:CreateSecurityGroup",
        "ec2:CreateSnapshot", "ec2:CreateTags", "ec2:CreateVolume",
        "ec2:DeleteKeyPair", "ec2:DeleteSecurityGroup", "ec2:DeleteSnapshot",
        "ec2:DeleteVolume", "ec2:DeregisterImage",
        "ec2:DescribeImageAttribute", "ec2:DescribeImages",
        "ec2:DescribeInstances", "ec2:DescribeInstanceStatus",
        "ec2:DescribeRegions", "ec2:DescribeSecurityGroups",
        "ec2:DescribeSnapshots", "ec2:DescribeSubnets",
        "ec2:DescribeTags", "ec2:DescribeVolumes", "ec2:DescribeVpcs",
        "ec2:DetachVolume", "ec2:GetPasswordData",
        "ec2:ModifyImageAttribute", "ec2:ModifyInstanceAttribute",
        "ec2:ModifySnapshotAttribute", "ec2:RegisterImage",
        "ec2:RunInstances", "ec2:StopInstances", "ec2:TerminateInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PackerIAMInstanceProfile",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:CreateRole", "iam:DeleteRole",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRole"
      ],
      "Resource": [
        "arn:aws:iam::${ACCOUNT_ID}:instance-profile/packer_*",
        "arn:aws:iam::${ACCOUNT_ID}:role/packer_*"
      ]
    },
    {
      "Sid": "AMIManifestSSM",
      "Effect": "Allow",
      "Action": ["ssm:PutParameter", "ssm:GetParameter"],
      "Resource": "arn:aws:ssm:*:${ACCOUNT_ID}:parameter/eks-d-xpress/*"
    },
    {
      "Sid": "AMISigning",
      "Effect": "Allow",
      "Action": ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"],
      "Resource": "arn:aws:kms:*:${ACCOUNT_ID}:key/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Usage": "eks-d-xpress-ami-signing"
        }
      }
    }
  ]
}
EOF
)"
echo "    ✓ Policy attached"

# ── 4. KMS signing key ─────────────────────────────────────────────────────
echo "==> Setting up KMS signing key..."
EXISTING_KEY_ID=$(aws kms list-aliases --region "${AWS_REGION}" \
  --query "Aliases[?AliasName=='${KEY_ALIAS}'].TargetKeyId" --output text 2>/dev/null || true)

if [ -z "${EXISTING_KEY_ID}" ]; then
  KEY_ID=$(aws kms create-key \
    --region "${AWS_REGION}" \
    --key-usage SIGN_VERIFY \
    --key-spec RSA_4096 \
    --description "EKS-DX AMI attestation signing key" \
    --tags TagKey=Usage,TagValue=eks-d-xpress-ami-signing \
             TagKey=ManagedBy,TagValue=eks-d-xpress \
    --query 'KeyMetadata.KeyId' --output text)
  aws kms create-alias --region "${AWS_REGION}" \
    --alias-name "${KEY_ALIAS}" --target-key-id "${KEY_ID}"
  echo "    ✓ KMS key created: ${KEY_ID}"
else
  KEY_ID="${EXISTING_KEY_ID}"
  echo "    ✓ KMS key already exists: ${KEY_ID}"
fi

KEY_ARN=$(aws kms describe-key --region "${AWS_REGION}" \
  --key-id "${KEY_ID}" --query 'KeyMetadata.Arn' --output text)

# Store key ARN in SSM so the pipeline can reference it without hardcoding
aws ssm put-parameter --region "${AWS_REGION}" \
  --name "/eks-d-xpress/infra/kms/ami-signing-key-arn" \
  --value "${KEY_ARN}" \
  --type String --overwrite
echo "    ✓ Key ARN stored at /eks-d-xpress/infra/kms/ami-signing-key-arn"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Setup complete — add these to your GitHub repo:           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Variable  AWS_REGION      = ${AWS_REGION}"
echo "║  Secret    AWS_PACKER_ROLE_ARN = ${ROLE_ARN}"
echo "╚══════════════════════════════════════════════════════════════╝"
