#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"

usage() {
  cat <<EOF
EKS-D-Xpress Deployment Bundle

Usage:
  deploy.sh deploy [--stack <name>] [--region <region>]
  deploy.sh destroy [--stack <name>] [--region <region>]
  deploy.sh register-amis [--region <region>]
  deploy.sh install-charts [--kubeconfig <path>]
  deploy.sh verify-ami --ami-id <id> [--sig-file <path>]
  deploy.sh import-ami --ami-id <id> --regions <r1,r2> [--src-region <r>]
  deploy.sh eks-dx <cli-args...>
  deploy.sh --help

Stacks:
  infra           Shared VPC infrastructure
  control-plane   Serverless control plane (Lambdas, API GW, DynamoDB)
  all             Deploy all stacks in order (default)

Examples:
  deploy.sh deploy --region eu-west-1
  deploy.sh deploy --stack infra
  deploy.sh destroy --stack control-plane
  deploy.sh register-amis --region us-east-1
  deploy.sh verify-ami --ami-id ami-0abc1234def56789
  deploy.sh import-ami --ami-id ami-0abc1234def56789 --regions us-east-1,eu-west-1
  deploy.sh eks-dx clusters list
EOF
  exit 0
}

cdk_bootstrap() {
  local account
  account=$(aws sts get-caller-identity --query Account --output text)
  echo "==> CDK Bootstrap (aws://${account}/${REGION})"
  cdk bootstrap "aws://${account}/${REGION}" --quiet 2>/dev/null || true
}

deploy_infra() {
  echo "==> Deploying EksDxSharedInfraStack"
  cd "${SCRIPT_DIR}/infra"
  cdk deploy --app cdk.out --all --require-approval never \
    --region "${REGION}" \
    --context region="${REGION}"
}

deploy_control_plane() {
  echo "==> Deploying EksDXpressControlPlaneStack"
  cd "${SCRIPT_DIR}/control-plane"
  cdk deploy --app cdk.out --all --require-approval never \
    --region "${REGION}" \
    --context region="${REGION}"
}

register_amis() {
  echo "==> Registering golden AMI IDs to SSM"
  local manifest="${SCRIPT_DIR}/ami-manifest.json"
  [[ -f "$manifest" ]] || { echo "ERROR: ami-manifest.json not found"; exit 1; }

  python3 -c "
import json, subprocess, os

region = os.environ.get('AWS_REGION', 'us-east-1')
manifest = json.load(open('${manifest}'))

for k8s_ver, arches in manifest.items():
    for arch, regions in arches.items():
        ami_id = regions.get(region)
        if not ami_id:
            print(f'  SKIP: No AMI for {arch}/{k8s_ver} in {region}')
            continue
        param = f'/eks-d-xpress/infra/ami/{arch}/{k8s_ver}'
        subprocess.run([
            'aws', 'ssm', 'put-parameter',
            '--name', param,
            '--value', ami_id,
            '--type', 'String',
            '--overwrite',
            '--region', region
        ], check=True)
        print(f'  ✓ {param} = {ami_id}')
"
}

install_charts() {
  echo "==> Installing Helm charts"
  local kubeconfig="${KUBECONFIG:-/root/.kube/config}"
  for chart in "${SCRIPT_DIR}"/helm/*.tar.gz; do
    [[ -f "$chart" ]] || continue
    echo "  Installing $(basename "$chart")"
    helm upgrade --install "$(basename "$chart" .tar.gz)" "$chart" \
      --kubeconfig "$kubeconfig" \
      --create-namespace
  done
}

# ─── Main ───────────────────────────────────────────────────────────
COMMAND="${1:-}"
[[ -z "$COMMAND" || "$COMMAND" == "--help" || "$COMMAND" == "-h" ]] && usage
shift

STACK="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)      STACK="$2"; shift 2 ;;
    --region)     REGION="$2"; export AWS_REGION="$2"; shift 2 ;;
    --kubeconfig) export KUBECONFIG="$2"; shift 2 ;;
    *)            break ;;
  esac
done

export CDK_DEFAULT_REGION="${REGION}"
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

case "$COMMAND" in
  deploy)
    cdk_bootstrap
    case "$STACK" in
      all)
        deploy_infra
        register_amis
        deploy_control_plane
        ;;
      infra)          deploy_infra ;;
      control-plane)  deploy_control_plane ;;
      *) echo "Unknown stack: $STACK"; exit 1 ;;
    esac
    echo ""; echo "✓ Deployment complete (region=${REGION})"
    ;;
  destroy)
    case "$STACK" in
      all)
        cd "${SCRIPT_DIR}/control-plane" && cdk destroy --app cdk.out --all --force --region "${REGION}" || true
        cd "${SCRIPT_DIR}/infra" && cdk destroy --app cdk.out --all --force --region "${REGION}" || true
        ;;
      infra)          cd "${SCRIPT_DIR}/infra" && cdk destroy --app cdk.out --all --force --region "${REGION}" ;;
      control-plane)  cd "${SCRIPT_DIR}/control-plane" && cdk destroy --app cdk.out --all --force --region "${REGION}" ;;
      *) echo "Unknown stack: $STACK"; exit 1 ;;
    esac
    echo "✓ Destroy complete"
    ;;
  register-amis)
    register_amis
    ;;
  install-charts)
    install_charts
    ;;
  verify-ami)
    exec "${SCRIPT_DIR}/bin/verify-ami.sh" \
      --sig-file "${SCRIPT_DIR}/ami-signatures.json" \
      --pubkey   "${SCRIPT_DIR}/eks-d-xpress-ami-signing.pub.pem" \
      "$@"
    ;;
  import-ami)
    exec "${SCRIPT_DIR}/bin/import-ami.sh" \
      --sig-file "${SCRIPT_DIR}/ami-signatures.json" \
      "$@"
    ;;
  eks-dx)
    exec "${SCRIPT_DIR}/bin/eks-dx" "$@"
    ;;
  *)
    echo "Unknown command: $COMMAND"
    usage
    ;;
esac
