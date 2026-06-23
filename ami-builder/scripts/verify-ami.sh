#!/usr/bin/env bash
# verify-ami.sh — verify an EKS-D-Xpress AMI cryptographic signature.
#
# Reads the signature and attestation metadata from ami-signatures.json
# (shipped with every release) and verifies against the RSA-4096 public key
# bundled in this repository. No AWS credentials or SSM access required.
#
# Usage:
#   ./ami-builder/scripts/verify-ami.sh \
#     --ami-id   ami-0abc1234def56789 \
#     --sig-file /path/to/ami-signatures.json   # default: <script-dir>/../ami-signatures.json
#     --pubkey   /path/to/pubkey.pem             # default: bundled eks-d-xpress-ami-signing.pub.pem
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AMI_ID=""
SIG_FILE="${SCRIPT_DIR}/../ami-signatures.json"
PUBKEY="${SCRIPT_DIR}/../eks-d-xpress-ami-signing.pub.pem"

while [[ $# -gt 0 ]]; do
  case $1 in
    --ami-id)   AMI_ID=$2;    shift 2 ;;
    --sig-file) SIG_FILE=$2;  shift 2 ;;
    --pubkey)   PUBKEY=$2;    shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${AMI_ID}" ]]       || { echo "ERROR: --ami-id is required" >&2; exit 1; }
[[ -f "${SIG_FILE}" ]]     || { echo "ERROR: sig file not found: ${SIG_FILE}" >&2; exit 1; }
[[ -f "${PUBKEY}" ]]       || { echo "ERROR: public key not found: ${PUBKEY}" >&2; exit 1; }

python3 - <<PYEOF
import json, sys, base64, tempfile, os, subprocess

ami_id, sig_file, pubkey = "${AMI_ID}", "${SIG_FILE}", "${PUBKEY}"

signatures = json.load(open(sig_file))
entry = signatures.get(ami_id)
if not entry:
    print(f"ERROR: {ami_id} not found in {sig_file}", file=sys.stderr)
    sys.exit(1)

attestation = json.dumps({
    "ami_id":             ami_id,
    "arch":               entry["arch"],
    "kubernetes_version": entry["kubernetes_version"],
    "ami_version":        entry["ami_version"],
    "timestamp":          entry["timestamp"],
}, sort_keys=True)

with tempfile.TemporaryDirectory() as d:
    msg_file = os.path.join(d, "attestation.json")
    sig_file_tmp = os.path.join(d, "attestation.sig")
    with open(msg_file, "w") as f: f.write(attestation)
    with open(sig_file_tmp, "wb") as f: f.write(base64.b64decode(entry["signature"]))

    result = subprocess.run([
        "openssl", "dgst", "-sha256", "-verify", pubkey,
        "-sigopt", "rsa_padding_mode:pkcs1",
        "-signature", sig_file_tmp, msg_file,
    ], capture_output=True, text=True)

if result.returncode == 0:
    print(f"✓ Signature VALID — {ami_id} ({entry['arch']}, k8s {entry['kubernetes_version']}, version {entry['ami_version']})")
else:
    print(f"✗ Signature INVALID — {ami_id}", file=sys.stderr)
    print(result.stderr, file=sys.stderr)
    sys.exit(1)
PYEOF
