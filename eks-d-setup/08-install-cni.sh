#!/bin/bash
set -e

# Disable amazon-ec2-net-utils policy-routes before CNI install.
#
# On AL2023, policy-routes@.service creates "from <ip> lookup <table>" ip rules
# for ENI secondary IPs. VPC CNI assigns those same IPs to pods — when the
# policy-routes rules exist, pod traffic to 169.254.169.254 (IMDS) gets routed
# through per-ENI tables that lack a link-local route, making IMDS unreachable.
# This breaks EBS CSI, cloud-provider-aws, and any pod relying on instance metadata.
echo "Disabling ec2-net-utils policy-routes (conflicts with VPC CNI)..."
sudo systemctl disable --now policy-routes@ens5.service policy-routes@ens6.service 2>/dev/null || true
sudo systemctl disable --now refresh-policy-routes@ens5.timer refresh-policy-routes@ens6.timer 2>/dev/null || true

sudo rm -f /run/systemd/network/70-ens*.network.d/ec2net_alias.conf
sudo networkctl reload 2>/dev/null || true
for iface in $(ip -o link show | awk -F: '/ens/{print $2}' | tr -d ' '); do
  ip -4 addr show dev "$iface" scope global | grep '/32' | awk '{print $2}' | while read addr; do
    sudo ip addr del "$addr" dev "$iface" 2>/dev/null || true
  done
done
ip rule show | grep "proto static" | while read line; do
  prio=$(echo "$line" | cut -d: -f1)
  rule=$(echo "$line" | sed "s/^[0-9]*:\t//")
  sudo ip rule del priority "$prio" $rule 2>/dev/null || true
done
sudo ip route flush cache 2>/dev/null || true
echo "✓ ec2-net-utils policy-routes disabled"

# Ensure EC2 API is reachable — IPAMD calls DescribeNetworkInterfaces on startup.
echo "Waiting for EC2 API reachability..."
for i in $(seq 1 15); do
  curl -s --connect-timeout 2 "https://ec2.${AWS_REGION}.amazonaws.com" >/dev/null 2>&1 && {
    echo "✓ EC2 API reachable (${AWS_REGION})"
    break
  }
  [ "$i" -eq 15 ] && echo "Warning: EC2 API not confirmed after 15s, proceeding anyway"
  sleep 1
done

echo "Installing AWS VPC CNI v1.20.4..."

# If CNI binaries aren't pre-baked in the AMI, extract them from the init container
# image now so the daemonset init container finds them and skips extraction.
if [ -z "$(ls /opt/cni/bin/ 2>/dev/null)" ]; then
  echo "CNI binaries not pre-baked — extracting from init container image..."
  CNI_INIT_IMG=$(grep "image:" /opt/eks-d/manifests/aws-vpc-cni.yaml 2>/dev/null | grep "cni-init" | head -1 | awk '{print $2}')
  if [ -n "$CNI_INIT_IMG" ]; then
    sudo mkdir -p /opt/cni/bin
    docker create --name cni-prebake "$CNI_INIT_IMG" 2>/dev/null && \
      sudo docker cp cni-prebake:/opt/cni/bin/. /opt/cni/bin/ && \
      docker rm cni-prebake || docker rm -f cni-prebake 2>/dev/null || true
    echo "✓ CNI binaries extracted to /opt/cni/bin"
  fi
else
  echo "✓ CNI binaries already present at /opt/cni/bin — skipping extraction"
fi

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
