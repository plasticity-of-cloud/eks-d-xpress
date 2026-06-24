#!/bin/bash
set -e
source /tmp/ami-build.env
MANIFESTS_DIR="/opt/eks-d/manifests"

echo "  Downloading VPC CNI manifest (v1.20.4)..."
sudo mkdir -p "${MANIFESTS_DIR}"
sudo curl -sL \
  "https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.20.4/config/master/aws-k8s-cni.yaml" \
  -o "${MANIFESTS_DIR}/aws-vpc-cni.yaml"

echo "  Patching manifest for prefix delegation..."
python3 - "${MANIFESTS_DIR}/aws-vpc-cni.yaml" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
with open(path) as f:
    docs = list(yaml.safe_load_all(f))

REMOVE_VARS = {"WARM_IP_TARGET", "MINIMUM_IP_TARGET"}
SET_VARS = {"ENABLE_PREFIX_DELEGATION": "true", "WARM_PREFIX_TARGET": "1", "WARM_ENI_TARGET": "0"}

for doc in docs:
    if not isinstance(doc, dict) or doc.get("kind") != "DaemonSet":
        continue
    for container in doc["spec"]["template"]["spec"].get("containers", []):
        env = [e for e in container.get("env", []) if e.get("name") not in REMOVE_VARS]
        seen = {e["name"] for e in env if e.get("name") in SET_VARS}
        for e in env:
            if e.get("name") in SET_VARS:
                e["value"] = SET_VARS[e["name"]]
        env += [{"name": k, "value": v} for k, v in SET_VARS.items() if k not in seen]
        container["env"] = env

with open(path, "w") as f:
    yaml.dump_all(docs, f, default_flow_style=False, allow_unicode=True)
PYEOF
sudo chown root:root "${MANIFESTS_DIR}/aws-vpc-cni.yaml"
echo "  ✓ Manifest patched (ENABLE_PREFIX_DELEGATION=true, WARM_PREFIX_TARGET=1, WARM_ENI_TARGET=0)"

# VPC CNI images live in a fixed account/region regardless of builder region
VPC_CNI_ECR_REGION="us-west-2"
VPC_CNI_ECR_TOKEN=$(aws ecr get-login-password --region "${VPC_CNI_ECR_REGION}")

echo "  Pulling VPC CNI images (602401143452.dkr.ecr.us-west-2)..."
python3 "${EXTRACT_IMAGES_PY}" < "${MANIFESTS_DIR}/aws-vpc-cni.yaml" | sort -u | while read img; do
  sudo ctr -n k8s.io images pull --user "AWS:${VPC_CNI_ECR_TOKEN}" "$img" || true
done

echo "  Pre-baking CNI binaries from init container..."
CNI_INIT_IMG=$(grep "image:" "${MANIFESTS_DIR}/aws-vpc-cni.yaml" | grep "cni-init" | head -1 | awk '{print $2}')
if [ -n "$CNI_INIT_IMG" ]; then
  sudo mkdir -p /opt/cni/bin
  CTR_SNAPSHOT="cni-prebake-$$"
  sudo ctr -n k8s.io snapshots prepare "$CTR_SNAPSHOT" \
    "$(sudo ctr -n k8s.io images list -q name=="$CNI_INIT_IMG" 2>/dev/null | head -1)" 2>/dev/null || true
  CTR_MNT=$(sudo ctr -n k8s.io snapshots mounts /tmp/cni-mnt-$$ "$CTR_SNAPSHOT" 2>/dev/null | head -1)
  if [ -n "$CTR_MNT" ]; then
    sudo mkdir -p /tmp/cni-mnt-$$
    eval "sudo $CTR_MNT"
    sudo cp -a /tmp/cni-mnt-$$/opt/cni/bin/. /opt/cni/bin/ 2>/dev/null || true
    sudo umount /tmp/cni-mnt-$$ 2>/dev/null || true
    sudo rm -rf /tmp/cni-mnt-$$
    sudo ctr -n k8s.io snapshots rm "$CTR_SNAPSHOT" 2>/dev/null || true
  else
    sudo ctr -n k8s.io run --rm \
      --mount type=bind,src=/opt/cni/bin,dst=/host/opt/cni/bin,options=rbind:rw \
      "$CNI_INIT_IMG" "cni-prebake-$$" \
      sh -c "cp -a /opt/cni/bin/. /host/opt/cni/bin/" 2>/dev/null || true
  fi
  echo "  ✓ CNI binaries baked to /opt/cni/bin ($(ls /opt/cni/bin 2>/dev/null | wc -l) files)"
else
  echo "  Warning: could not determine CNI init image — /opt/cni/bin not pre-baked"
fi

echo "✓ vpc-cni ready"
