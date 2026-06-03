#!/bin/bash
set -e

echo "Preparing etcd volume..."

# Check if volume is already mounted
if mountpoint -q /var/lib/etcd; then
  echo "✓ etcd volume already mounted"
  df -h /var/lib/etcd
  exit 0
fi

# Check if volume is already formatted
if sudo blkid /dev/nvme1n1 | grep -q ext4; then
  echo "Volume already formatted, mounting..."
else
  echo "Formatting etcd volume..."
  sudo mkfs.ext4 /dev/nvme1n1
fi

echo "Creating mount point..."
sudo mkdir -p /var/lib/etcd

echo "Mounting volume..."
sudo mount /dev/nvme1n1 /var/lib/etcd

echo "Removing lost+found..."
sudo rm -rf /var/lib/etcd/lost+found

echo "Adding to fstab..."
if ! grep -q '/var/lib/etcd' /etc/fstab; then
  echo '/dev/nvme1n1 /var/lib/etcd ext4 defaults 0 2' | sudo tee -a /etc/fstab
fi

echo "✓ etcd volume prepared"
df -h /var/lib/etcd
