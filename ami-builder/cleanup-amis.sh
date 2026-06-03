#!/bin/bash
set -e

# EKS-DX AMI Cleanup Script
# Deletes all EKS-DX AMIs owned by the current account

echo "=========================================="
echo "EKS-DX AMI Cleanup"
echo "=========================================="

# Get all EKS-DX AMIs
AMIS=$(aws ec2 describe-images --owners self --filters "Name=name,Values=eks-dx-*" --query "Images[*].{ImageId:ImageId,Name:Name,CreationDate:CreationDate}" --output json)

if [ "$(echo "$AMIS" | jq length)" -eq 0 ]; then
  echo "No EKS-DX AMIs found to delete."
  exit 0
fi

echo "Found EKS-DX AMIs:"
echo "$AMIS" | jq -r '.[] | "\(.ImageId) - \(.Name) (\(.CreationDate))"'
echo ""

# Confirm deletion
read -p "Delete all these AMIs? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""
echo "Deleting AMIs and snapshots..."

# Collect all AMI-snapshot mappings first
declare -A ami_snapshots
echo "$AMIS" | jq -r '.[].ImageId' | while read ami_id; do
  SNAPSHOTS=$(aws ec2 describe-images --image-ids "$ami_id" --query "Images[0].BlockDeviceMappings[?Ebs].Ebs.SnapshotId" --output text | grep -v '^$' || true)
  if [ -n "$SNAPSHOTS" ]; then
    echo "$ami_id:$SNAPSHOTS" >> /tmp/ami_snapshots.txt
  else
    echo "$ami_id:" >> /tmp/ami_snapshots.txt
  fi
done

# Deregister all AMIs first
echo "$AMIS" | jq -r '.[].ImageId' | while read ami_id; do
  echo "Deregistering AMI: $ami_id"
  aws ec2 deregister-image --image-id "$ami_id"
done

# Then delete all snapshots
while IFS=':' read -r ami_id snapshots; do
  if [ -n "$snapshots" ]; then
    echo "Deleting snapshots for $ami_id: $snapshots"
    echo "$snapshots" | xargs -n1 aws ec2 delete-snapshot --snapshot-id
  fi
  echo "✓ Deleted $ami_id and associated snapshots"
done < /tmp/ami_snapshots.txt

# Cleanup temp file
rm -f /tmp/ami_snapshots.txt

echo ""
echo "✓ All EKS-DX AMIs and snapshots deleted successfully!"
