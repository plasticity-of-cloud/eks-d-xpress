#!/bin/bash
# progress.sh — DynamoDB progress reporting for EKS-DX boot scripts.
# Source this file from workstation-boot.sh or any boot script.
#
# Requires: TENANT_ID, AWS_REGION (from cluster.env)
# Optional: EKS_DX_TENANTS_TABLE (defaults to eks-dx-tenants)

EKS_DX_TENANTS_TABLE="${EKS_DX_TENANTS_TABLE:-eks-dx-tenants}"

# Update progress in DynamoDB. Called by boot scripts at each step.
# Usage: update_progress <state> <phase> <progress_percent>
update_progress() {
  local state=$1 phase=$2 progress=$3

  # Skip if TENANT_ID not set (e.g. manual run without cluster.env)
  [ -z "${TENANT_ID:-}" ] && return 0

  aws dynamodb update-item \
    --table-name "${EKS_DX_TENANTS_TABLE}" \
    --key "{\"tenantId\":{\"S\":\"${TENANT_ID}\"}}" \
    --update-expression "SET #s = :s, phase = :p, progress = :n, updatedAt = :t" \
    --expression-attribute-names '{"#s":"state"}' \
    --expression-attribute-values "{
      \":s\":{\"S\":\"${state}\"},
      \":p\":{\"S\":\"${phase}\"},
      \":n\":{\"N\":\"${progress}\"},
      \":t\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}
    }" \
    --region "${AWS_REGION}" 2>/dev/null || true
}

# Report failure to DynamoDB and exit.
# Usage: fail "error message"
fail() {
  local msg=$1

  [ -z "${TENANT_ID:-}" ] && { echo "FATAL: $msg"; exit 1; }

  aws dynamodb update-item \
    --table-name "${EKS_DX_TENANTS_TABLE}" \
    --key "{\"tenantId\":{\"S\":\"${TENANT_ID}\"}}" \
    --update-expression "SET #s = :s, #e = :e, updatedAt = :t" \
    --expression-attribute-names '{"#s":"state","#e":"error"}' \
    --expression-attribute-values "{
      \":s\":{\"S\":\"failed\"},
      \":e\":{\"S\":\"${msg}\"},
      \":t\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}
    }" \
    --region "${AWS_REGION}" 2>/dev/null || true

  exit 1
}

# Report ready state with public IP.
# Usage: report_ready
report_ready() {
  local public_ip
  local token
  token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60" -m 2 2>/dev/null)
  public_ip=$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")

  [ -z "${TENANT_ID:-}" ] && return 0

  aws dynamodb update-item \
    --table-name "${EKS_DX_TENANTS_TABLE}" \
    --key "{\"tenantId\":{\"S\":\"${TENANT_ID}\"}}" \
    --update-expression "SET #s = :s, phase = :p, progress = :n, publicIp = :ip, updatedAt = :t" \
    --expression-attribute-names '{"#s":"state"}' \
    --expression-attribute-values "{
      \":s\":{\"S\":\"ready\"},
      \":p\":{\"S\":\"Cluster ready\"},
      \":n\":{\"N\":\"100\"},
      \":ip\":{\"S\":\"${public_ip}\"},
      \":t\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}
    }" \
    --region "${AWS_REGION}" 2>/dev/null || true
}
