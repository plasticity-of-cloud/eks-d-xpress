# AMI Signature Verification

Every EKS-D-Xpress AMI is signed with an RSA-4096 KMS key after it is built.
The public key is committed to this repository so you can verify any AMI
without needing access to our AWS account.

## Prerequisites

- `openssl` (any modern version)
- `python3`
- `ami-signatures.json` from the [GitHub release](https://github.com/plasticity-of-cloud/eks-d-xpress/releases)

## Verify an AMI

```bash
# Download verification assets from the release
gh release download v1.0.3 \
  --repo plasticity-of-cloud/eks-d-xpress \
  --pattern "verify-ami.sh" \
  --pattern "ami-signatures.json" \
  --pattern "eks-d-xpress-ami-signing.pub.pem"

chmod +x verify-ami.sh
./verify-ami.sh --ami-id <AMI_ID>
```

Expected output on success:
```
✓ Signature VALID — ami-0d6cfeff13291c39e (arm64, k8s 1.35, version 20260611-0156)
```

### Finding the AMI ID and version

| Source | Command |
|--------|---------|
| AWS Console | EC2 → AMIs → search `eks-d-xpress` → owned by account `864899852480` |
| AWS CLI | `aws ec2 describe-images --owners 864899852480 --filters "Name=name,Values=eks-d-xpress-arm64-*" --query "sort_by(Images,&CreationDate)[-1].{ID:ImageId,Name:Name}"` |
| AMI tag | The `Name` tag on the AMI is `eks-d-xpress-<arch>-<VERSION>` |

The `VERSION` is the `<DATE>-<TIME>` suffix in the AMI name, e.g. `20260611-0156`.

## How verification works

The build pipeline creates a JSON attestation for each AMI:

```json
{
  "ami_id":             "ami-0d6cfeff13291c39e",
  "arch":               "arm64",
  "ami_version":        "20260611-0156",
  "kubernetes_version": "1.35",
  "timestamp":          "2026-06-11T02:02:09.123456Z"
}
```

The signature is stored in our AWS SSM Parameter Store (internal) and bundled as `ami-signatures.json` in every release. The `verify-ami.sh` script reads the signature from that file, reconstructs the attestation, and verifies it against `eks-d-xpress-ami-signing.pub.pem`. No AWS credentials are required.

The timestamp is also stamped as a `SigningTimestamp` tag on the AMI itself,
so you can inspect it independently:

```bash
aws ec2 describe-tags \
  --filters "Name=resource-id,Values=<AMI_ID>" \
  --query "Tags[?Key=='SigningTimestamp' || Key=='Signed' || Key=='SigningKeyArn']"
```

## Public key fingerprint

```
ami-builder/eks-d-xpress-ami-signing.pub.pem
SHA-256: 99fd42ec9397f28a5e99d6374f390d474562f64ae3ac570776b21320a2ec43ad
```

To compute it yourself:
```bash
openssl pkey -pubin -in ami-builder/eks-d-xpress-ami-signing.pub.pem \
  -outform DER | openssl dgst -sha256
```
