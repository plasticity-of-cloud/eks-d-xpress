#!/usr/bin/env bash
# import-ami.sh — verify an EKS-D-Xpress AMI signature, then copy it into
# the caller's AWS account and optionally replicate to additional regions.
#
# Prerequisites:
#   - AWS CLI configured with credentials for YOUR account (target)
#   - openssl, python3
#   - ami-signatures.json from the release (or bundled copy)
#
# Usage:
#   ./ami-builder/scripts/import-ami.sh \
#     --ami-id     ami-0abc1234def56789 \
#     --src-region us-east-1 \
#     --regions    us-east-1,eu-west-1,ap-southeast-1 \
#     --sig-file   /path/to/ami-signatures.json   # default: bundled copy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AMI_ID=""
SRC_REGION="${AWS_REGION:-us-east-1}"
REGIONS=""
SIG_FILE="${SCRIPT_DIR}/../ami-signatures.json"

while [[ $# -gt 0 ]]; do
  case $1 in
    --ami-id)     AMI_ID=$2;      shift 2 ;;
    --src-region) SRC_REGION=$2;  shift 2 ;;
    --regions)    REGIONS=$2;     shift 2 ;;
    --sig-file)   SIG_FILE=$2;    shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${AMI_ID}" ]]   || { echo "ERROR: --ami-id is required" >&2; exit 1; }
[[ -n "${REGIONS}" ]]  || { echo "ERROR: --regions required (comma-separated)" >&2; exit 1; }

# ── Step 1: verify signature ──────────────────────────────────────────────
echo "==> Verifying AMI signature..."
"${SCRIPT_DIR}/verify-ami.sh" --ami-id "${AMI_ID}" --sig-file "${SIG_FILE}"

# ── Step 2: read metadata from sig file ──────────────────────────────────
read -r ARCH K8S_VERSION AMI_VERSION < <(python3 - <<PYEOF
import json, sys
e = json.load(open("${SIG_FILE}")).get("${AMI_ID}")
if not e: sys.exit(1)
print(e["arch"], e["kubernetes_version"], e["ami_version"])
PYEOF
)

# ── Step 3: copy to each target region ───────────────────────────────────
IFS=',' read -ra TARGET_REGIONS <<< "${REGIONS}"
for REGION in "${TARGET_REGIONS[@]}"; do
  echo "==> Copying ${AMI_ID} to ${REGION}..."
  NEW_AMI=$(aws ec2 copy-image \
    --source-image-id "${AMI_ID}" \
    --source-region "${SRC_REGION}" \
    --region "${REGION}" \
    --name "eks-d-xpress-${ARCH}-${AMI_VERSION}" \
    --description "EKS-D-Xpress k8s-${K8S_VERSION} ${ARCH} imported from ${SRC_REGION}" \
    --query "ImageId" --output text)

  echo "  ✓ ${REGION}: ${NEW_AMI} (pending — image copy is async)"

  aws ssm put-parameter \
    --region "${REGION}" \
    --name "/eks-d-xpress/infra/ami/${ARCH}/${K8S_VERSION}" \
    --value "${NEW_AMI}" \
    --type String --overwrite \
    --description "Imported from ${AMI_ID} (${SRC_REGION})" \
    --no-cli-pager
  echo "  ✓ SSM /eks-d-xpress/infra/ami/${ARCH}/${K8S_VERSION} = ${NEW_AMI}"
done

echo ""
echo "Import complete. AMI copies are async — wait for state=available before deploying:"
echo "  aws ec2 wait image-available --region <region> --image-ids <new-ami-id>"
