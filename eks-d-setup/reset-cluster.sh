#!/bin/bash
# reset-cluster.sh - Full cluster teardown for a clean reinstall
# Clears: kubeadm state, etcd volume, CNI config, iptables, kubeconfig
set -e

echo "=========================================="
echo "Full Cluster Reset"
echo "=========================================="

# Kill any running boot/install scripts
echo "Stopping any running install scripts..."
sudo pkill -f workstation-boot.sh 2>/dev/null || true
sudo pkill -f install-all.sh 2>/dev/null || true

# Stop kubelet so it doesn't fight us
echo "Stopping kubelet..."
sudo systemctl stop kubelet 2>/dev/null || true

# kubeadm reset clears: /etc/kubernetes/manifests, /etc/kubernetes/pki,
# /var/lib/kubelet, /etc/kubernetes/*.conf, /var/lib/etcd contents
echo "Running kubeadm reset..."
sudo kubeadm reset --force 2>&1 || true

# CNI config and state
echo "Cleaning CNI state..."
sudo rm -rf /etc/cni/net.d/*
sudo rm -rf /var/lib/cni/
sudo rm -rf /run/flannel/ 2>/dev/null || true

# Remove CNI network interfaces left behind
for iface in cni0 flannel.1 dummy0; do
  sudo ip link delete "$iface" 2>/dev/null || true
done

# Flush iptables rules added by kube-proxy and CNI
echo "Flushing iptables..."
sudo iptables -F 2>/dev/null || true
sudo iptables -t nat -F 2>/dev/null || true
sudo iptables -t mangle -F 2>/dev/null || true
sudo iptables -X 2>/dev/null || true
sudo ipvsadm --clear 2>/dev/null || true

# Reformat etcd volume so it starts completely clean
echo "Reformatting etcd volume..."
sudo umount /var/lib/etcd 2>/dev/null || true
sudo mkfs.ext4 -F /dev/nvme1n1
sudo mount /dev/nvme1n1 /var/lib/etcd
sudo rm -rf /var/lib/etcd/lost+found
echo "✓ etcd volume reformatted and mounted"

# Recreate manifests dir (kubeadm reset deletes it)
sudo mkdir -p /etc/kubernetes/manifests

# Remove kubeconfig
rm -rf "$HOME/.kube"

# Remove installation marker so workstation-boot.sh can run again
sudo rm -f /opt/eks-d/.installation_complete

echo ""
echo "=========================================="
echo "✓ Reset complete - ready for fresh install"
echo "=========================================="
