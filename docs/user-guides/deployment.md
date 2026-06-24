# Deployment Guide

EKS-D-Xpress has two deployment surfaces:

1. **Platform deployment** — deploys shared AWS infrastructure and the EKS-DX control plane
   into a customer AWS account (CDK stacks via the deployment bundle)
2. **Cluster boot** — installs EKS-D on an EC2 instance provisioned by the platform
   (runs automatically as part of instance user data)

---

## 1. Platform Deployment (deployment bundle)

The platform is deployed as a single Docker image that bundles pre-synthesized CDK stacks,
AMI manifests, Helm charts, and the `eks-dx` CLI. No Java or Terraform is required.

### Prerequisites

- Docker
- AWS credentials with admin-level permissions (or scoped for CDK bootstrap + deploy)

### Deploy

```bash
# Mount credentials, set region, run deploy
docker run --rm \
  -v ~/.aws:/root/.aws:ro \
  -e AWS_PROFILE=my-profile \
  -e AWS_REGION=us-east-1 \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  deploy --region us-east-1
```

This runs the following sequence automatically:

1. CDK bootstrap (idempotent)
2. `EksDxSharedInfraStack` — VPC, launch templates, ECR pull-through cache, SSM params
3. Register golden AMI IDs to SSM (`/eks-d-xpress/infra/ami/{arch}/{k8s-version}`)
4. `EksDXpressControlPlaneStack` — Lambdas, API Gateway, DynamoDB, Pod Identity

### Deploy individual stacks

```bash
# Shared infrastructure only
docker run --rm -v ~/.aws:/root/.aws:ro \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  deploy --stack infra --region us-east-1

# Control plane only (requires infra deployed first)
docker run --rm -v ~/.aws:/root/.aws:ro \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  deploy --stack control-plane --region us-east-1
```

### Install Helm charts on a cluster

```bash
docker run --rm \
  -v ~/.aws:/root/.aws:ro \
  -v ~/.kube:/root/.kube:ro \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  install-charts --kubeconfig /root/.kube/config
```

### Destroy

```bash
docker run --rm -v ~/.aws:/root/.aws:ro \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  destroy --region us-east-1
```

See [DEPLOYMENT_BUNDLE.md](../DEPLOYMENT_BUNDLE.md) for full bundle documentation.

---

## 2. Cluster Boot (control plane EC2)

Once the platform is deployed, the EKS-DX control plane (Lambda) provisions EC2 instances.
Each instance runs `setup-eks-d.sh` automatically via systemd on first boot.

The script expects `/opt/eks-d/cluster.env` to be pre-seeded by the provisioner Lambda
before the instance starts. It contains `TENANT_ID`, `CLUSTER_NAME`, `NODE_IP`,
`AWS_REGION`, and optionally `EKS_DX_ENDPOINT`.

### Installation sequence

```
05-prepare-etcd.sh              # Format / mount etcd EBS volume
06-install-aws-iam-authenticator.sh
07-install-eks-d.sh             # kubeadm init
08-install-cni.sh               # AWS VPC CNI
09-install-cloud-provider.sh    # AWS Cloud Controller Manager
10-configure-node.sh            # Untaint control plane
11-install-cert-manager.sh
11b-install-kubelet-csr-approver.sh
12-install-eks-dx-pod-identity.sh  # Skipped if EKS_DX_ENDPOINT not set
13-install-ebs-csi.sh
14-install-metrics-server.sh
15-install-karpenter.sh
16-install-cloudwatch.sh
17-monitor-cloudwatch-rollout.sh
18-install-eks-dx-karpenter-support.sh
```

Total boot time: under 3 minutes.

### Manual / dev mode

For local development without a provisioner Lambda, write `cluster.env` manually and run
the script directly:

```bash
sudo mkdir -p /opt/eks-d
sudo tee /opt/eks-d/cluster.env <<EOF
TENANT_ID=alice
CLUSTER_NAME=alice-eks-dx-arm64
NODE_IP=$(hostname -I | awk '{print $1}')
AWS_REGION=us-east-1
EOF

cd eks-d-setup
sudo bash setup-eks-d.sh
```

`EKS_DX_ENDPOINT` is intentionally omitted in dev mode — step 12 (Pod Identity) is skipped
automatically.

### Verify

```bash
kubectl get nodes
kubectl get pods -A
```

---

## 3. Configure Node Pools

After the cluster is running, configure Karpenter node pools:

```bash
cd node-pools
./configure-nodepools.sh
```

To test scaling:

```bash
kubectl apply -f node-pools/test-workload.yaml
kubectl get nodes -w
```

---

## Troubleshooting

**Karpenter not provisioning nodes**
```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f
kubectl get events --field-selector reason=ProvisioningSucceeded
```

**Cluster boot failed mid-way**
```bash
# Check systemd service logs
journalctl -u eks-dx-boot -f

# Re-run from where it left off (scripts are idempotent)
sudo bash /home/ec2-user/eks-d-setup/setup-eks-d.sh
```

**Worker nodes not joining**
```bash
kubectl get events --sort-by='.lastTimestamp' | head -20
```
