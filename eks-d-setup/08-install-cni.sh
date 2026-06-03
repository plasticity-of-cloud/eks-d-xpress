#!/bin/bash
set -e

# Disable amazon-ec2-net-utils policy-routes.
#
# On AL2023, ec2-net-utils does two things that break VPC CNI pod networking:
#   1. Adds ENI secondary IPs as /32 addresses on host interfaces. These land
#      in the kernel's local routing table (priority 0), so traffic to pod IPs
#      is delivered to the host stack instead of the pod network namespace.
#      Symptom: CoreDNS "connection refused" from host, DNS timeout from pods.
#   2. Creates "from <ip> lookup <table>" ip rules for secondary ENI IPs.
#      These route cross-ENI pod traffic through per-ENI tables that lack veth
#      routes, causing packets to loop through the VPC gateway.
#
# The fix: disable ec2-net-utils entirely and let VPC CNI manage all routing.
echo "Disabling ec2-net-utils policy-routes (conflicts with VPC CNI)..."
sudo systemctl disable --now policy-routes@ens5.service policy-routes@ens6.service 2>/dev/null || true
sudo systemctl disable --now refresh-policy-routes@ens5.timer refresh-policy-routes@ens6.timer 2>/dev/null || true

# Remove stale state
sudo rm -f /run/systemd/network/70-ens*.network.d/ec2net_alias.conf
sudo networkctl reload 2>/dev/null || true
for iface in $(ip -o link show | awk -F: '/ens/{print $2}' | tr -d ' '); do
  ip -4 addr show dev "$iface" scope global | grep '/32' | awk '{print $2}' | while read addr; do
    sudo ip addr del "$addr" dev "$iface" 2>/dev/null || true
  done
done
# Remove stale ip rules
ip rule show | grep "proto static" | while read line; do
  prio=$(echo "$line" | cut -d: -f1)
  rule=$(echo "$line" | sed "s/^[0-9]*:\t//")
  sudo ip rule del priority "$prio" $rule 2>/dev/null || true
done
sudo ip route flush cache 2>/dev/null || true
echo "✓ ec2-net-utils policy-routes disabled"

echo "Installing AWS VPC CNI v1.20.4..."

# AWS_VPC_K8S_CNI_EXTERNALSNAT=false is set in the manifest (default).
# SNAT pod traffic to node's primary IP for external destinations — required because
# secondary ENI IPs (pod IPs) have no public IP. Without SNAT, internet-bound
# packets from pods are dropped.

# Use pre-downloaded manifest if available
if [ -f /opt/eks-d/manifests/aws-vpc-cni.yaml ]; then
  kubectl apply -f /opt/eks-d/manifests/aws-vpc-cni.yaml
else
  kubectl apply -f https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/v1.20.4/config/master/aws-k8s-cni.yaml
fi

echo "Waiting for CNI pods to be ready..."
kubectl rollout status daemonset aws-node -n kube-system --timeout=120s || true

echo "✓ AWS VPC CNI installed"
kubectl get pods -n kube-system -l k8s-app=aws-node
