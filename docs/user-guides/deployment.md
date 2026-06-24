# Deployment Guide

EKS-D-Xpress ships as a Docker bundle. You drop into an interactive shell inside the
container, explore the tools, then run the provisioning script. No Java, no Terraform,
no local toolchain required beyond Docker.

---

## 1. Start the Bundle Shell

Pick the snippet that matches your environment and paste it into your terminal.

### From a workstation (credentials file)

```bash
docker run --rm -it \
  -v ~/.aws:/root/.aws:ro \
  -e AWS_PROFILE="${AWS_PROFILE:-default}" \
  -e AWS_REGION="${AWS_REGION:-us-east-1}" \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  bash
```

### From an EC2 instance or bastion host (instance profile / environment variables)

No credential files needed — the container inherits the environment:

```bash
docker run --rm -it \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  -e AWS_REGION="${AWS_REGION:-us-east-1}" \
  --network host \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  bash
```

> `--network host` lets the container reach the EC2 Instance Metadata Service
> (`169.254.169.254`) when running on an instance with an IAM role, without needing
> explicit credential env vars.

### From AWS CloudShell

CloudShell injects STS credentials as environment variables. Pass them through:

```bash
docker run --rm -it \
  -e AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN \
  -e AWS_REGION="${AWS_REGION:-us-east-1}" \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  bash
```

---

## 2. Explore the Shell

Once inside you have a fully equipped environment:

```
/opt/eks-dx/
├── deploy.sh          ← deployment orchestrator
├── bin/eks-dx         ← cluster management CLI
├── ami-manifest.json  ← golden AMI IDs by region and arch
├── infra/cdk.out/     ← EksDxSharedInfraStack (pre-synthesized)
├── control-plane/cdk.out/  ← EksDXpressControlPlaneStack
└── helm/              ← Helm charts
```

Verify your AWS identity before doing anything else:

```bash
aws sts get-caller-identity
```

Check which regions have golden AMIs available:

```bash
cat ami-manifest.json | python3 -m json.tool
```

List available deploy commands:

```bash
./deploy.sh --help
```

---

## 3. Deploy the Platform

Run the full deployment (CDK bootstrap → shared infra → AMI registration → control plane):

```bash
./deploy.sh deploy --region us-east-1
```

Or step by step if you want to inspect between stages:

```bash
# Step 1: shared VPC, launch templates, ECR pull-through cache
./deploy.sh deploy --stack infra --region us-east-1

# Step 2: register golden AMI IDs into SSM
./deploy.sh register-amis --region us-east-1

# Step 3: Lambdas, API Gateway, DynamoDB, Pod Identity
./deploy.sh deploy --stack control-plane --region us-east-1
```

What gets deployed:

| Stack | What it creates |
|-------|----------------|
| `EksDxSharedInfraStack` | VPC, launch templates, ECR pull-through cache, S3 endpoint, SSM params |
| AMI registration | `/eks-d-xpress/infra/ami/{arch}/{k8s-version}` SSM parameters |
| `EksDXpressControlPlaneStack` | Lambdas, API Gateway, DynamoDB, Pod Identity webhook |

---

## 4. Manage Clusters

Once the platform is deployed, use the `eks-dx` CLI inside the same shell:

```bash
# List clusters in your account
eks-dx clusters list

# Create a cluster (Lambda provisions an EC2 instance, boot takes ~3 min)
eks-dx clusters create --name my-cluster --region us-east-1

# Get kubeconfig
eks-dx clusters kubeconfig --name my-cluster > /tmp/kubeconfig
```

Install Helm charts on a running cluster:

```bash
./deploy.sh install-charts --kubeconfig /tmp/kubeconfig
```

---

## 5. Tear Down

```bash
# Destroy all stacks (control plane first, then infra)
./deploy.sh destroy --region us-east-1

# Or destroy individual stacks
./deploy.sh destroy --stack control-plane --region us-east-1
./deploy.sh destroy --stack infra --region us-east-1
```

---

## Cluster Boot Reference

When an EC2 instance is provisioned by the platform, it runs `setup-eks-d.sh`
automatically via systemd. The full install sequence is:

```
05-prepare-etcd.sh              → mount etcd EBS volume
06-install-aws-iam-authenticator.sh
07-install-eks-d.sh             → kubeadm init
08-install-cni.sh               → AWS VPC CNI
09-install-cloud-provider.sh    → AWS Cloud Controller Manager
10-configure-node.sh            → untaint control plane
11-install-cert-manager.sh
11b-install-kubelet-csr-approver.sh
12-install-eks-dx-pod-identity.sh   (skipped in dev mode)
13-install-ebs-csi.sh
14-install-metrics-server.sh
15-install-karpenter.sh
16-install-cloudwatch.sh
17-monitor-cloudwatch-rollout.sh
18-install-eks-dx-karpenter-support.sh
```

Total: under 3 minutes.

### Dev / manual mode

If you want to boot a cluster by hand (no provisioner Lambda):

```bash
sudo mkdir -p /opt/eks-d
sudo tee /opt/eks-d/cluster.env <<EOF
TENANT_ID=alice
CLUSTER_NAME=alice-eks-dx-arm64
NODE_IP=$(hostname -I | awk '{print $1}')
AWS_REGION=us-east-1
EOF

sudo bash /home/ec2-user/eks-d-setup/setup-eks-d.sh
```

`EKS_DX_ENDPOINT` is omitted → step 12 (Pod Identity) skips gracefully.

---

## Troubleshooting

**Credential check fails inside the container**
```bash
# Verify identity
aws sts get-caller-identity

# If using env vars, confirm they're set
env | grep AWS_
```

**Karpenter not provisioning nodes**
```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f
kubectl get events --field-selector reason=ProvisioningSucceeded
```

**Cluster boot stalled**
```bash
# On the control plane EC2:
journalctl -u eks-dx-boot -f
```

**Worker nodes not joining**
```bash
kubectl get events --sort-by='.lastTimestamp' | head -20
```
