# EKS-D-Xpress Deployment Bundle

A single multi-architecture Docker image that packages all pre-built CDK stacks, deployment scripts, and golden AMI references required to deploy the entire EKS-D-Xpress platform into a customer's AWS account.

## Overview

The bundle downloads pre-built release artifacts from GitHub and combines them into one deployable image:

| Stack | Source Repository | Release Artifact | What It Deploys |
|-------|-------------------|-----------------|-----------------|
| `EksDxSharedInfraStack` | `eks-d-xpress-infra` | `eks-d-xpress-infra-cdk-{ver}.tar.gz` | VPC, launch templates, ECR cache, S3 endpoint, SSM params |
| `EksDXpressControlPlaneStack` | `eks-d-xpress-control-plane` | `eks-dx-cdk-{ver}.tar.gz` | Lambdas, API Gateway, DynamoDB, Pod Identity |
| Golden AMIs | `eks-d-xpress` | `ami-manifest.json` | Pre-built machine images per region/arch |

Plus:
- **`eks-dx` CLI** — native binary from control-plane release (`eks-dx-cli-{ver}-linux-{arch}`)
- **Helm charts** — `eks-d-xpress-auth-proxy`, `eks-d-xpress-pod-identity-webhook`, `eks-d-xpress-karpenter-support`
- **Deployment orchestrator** — entrypoint script that sequences CDK deploys correctly

## How Release Artifacts Are Used

The control-plane release (e.g. `v1.0.3-rc20`) publishes 13 artifacts:

```
eks-dx-cli-{ver}-linux-amd64              # Native CLI (amd64)
eks-dx-cli-{ver}-linux-arm64              # Native CLI (arm64)
eks-dx-credential-service-{ver}.zip       # Lambda function zip (JVM, SnapStart)
eks-dx-mgmt-service-{ver}.zip             # Lambda function zip (JVM)
eks-dx-tenant-service-{ver}-arm64.zip     # Lambda function zip (native arm64)
eks-dx-tenant-service-{ver}-amd64.zip     # Lambda function zip (native amd64)
eks-dx-cdk-{ver}.tar.gz                   # Pre-synthesized CDK cloud assembly
eks-d-xpress-auth-proxy-{ver}.tar.gz      # Helm chart
eks-d-xpress-pod-identity-webhook-{ver}.tar.gz  # Helm chart
eks-d-xpress-karpenter-support-{ver}.tar.gz     # Helm chart
checksums.sha256
```

The **pre-synthesized CDK** (`eks-dx-cdk-{ver}.tar.gz`) contains a `cdk.out/` directory with:
- `EksDXpressControlPlaneStack.template.json` — CloudFormation template
- `asset.*.zip` — Lambda function zips (already bundled)
- `manifest.json` — CDK cloud assembly manifest

This means **no Java compilation at deploy time** — `cdk deploy --app cdk.out` works directly.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Docker Image: public.ecr.aws/amazoncorretto/amazoncorretto:25.0.3  │
│  (al2023-headless, linux/amd64 + linux/arm64)                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  /opt/eks-dx/                                                       │
│  ├── deploy.sh                  # Orchestrator entrypoint           │
│  ├── ami-manifest.json          # Golden AMI IDs by region/arch     │
│  ├── infra/                     # EksDxSharedInfraStack             │
│  │   └── cdk.out/              # Pre-synthesized (from release)     │
│  ├── control-plane/             # EksDXpressControlPlaneStack       │
│  │   └── cdk.out/              # Pre-synthesized (from release)     │
│  ├── helm/                      # Helm charts (.tar.gz)             │
│  │   ├── eks-d-xpress-auth-proxy-{ver}.tar.gz                       │
│  │   ├── eks-d-xpress-pod-identity-webhook-{ver}.tar.gz             │
│  │   └── eks-d-xpress-karpenter-support-{ver}.tar.gz                │
│  └── bin/                                                           │
│      └── eks-dx                 # Native CLI binary                 │
│                                                                     │
│  Installed tools:                                                   │
│  • AWS CDK CLI (npm)  — for `cdk deploy --app cdk.out`             │
│  • AWS CLI v2         — for SSM, STS, general AWS operations        │
│  • Node.js            — CDK CLI runtime                             │
│  • Helm              — for chart installation on clusters           │
│                                                                     │
│  NOT needed at runtime (pre-synthesized):                           │
│  • Java / Maven (only needed if re-synth with custom context)       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Customer Usage

### Basic Deployment

```bash
docker run --rm \
  -v ~/.aws:/root/.aws:ro \
  -e AWS_PROFILE=my-profile \
  -e AWS_REGION=us-east-1 \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  deploy --region us-east-1
```

### With Explicit Credentials

```bash
docker run --rm \
  -e AWS_ACCESS_KEY_ID=AKIA... \
  -e AWS_SECRET_ACCESS_KEY=... \
  -e AWS_SESSION_TOKEN=... \
  -e AWS_REGION=eu-west-1 \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  deploy --region eu-west-1
```

### Deploy Individual Stacks

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

### Register AMIs (Write AMI IDs to SSM)

```bash
docker run --rm -v ~/.aws:/root/.aws:ro \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  register-amis --region us-east-1
```

### Install Helm Charts on a Cluster

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

### Use the CLI

```bash
docker run --rm -v ~/.aws:/root/.aws:ro \
  ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest \
  eks-dx clusters list
```

## Deployment Sequence

The orchestrator (`deploy.sh`) enforces the correct order:

```
1. CDK Bootstrap (idempotent)
2. EksDxSharedInfraStack        → VPC, LTs, ECR cache, SSM params
3. Register AMI IDs to SSM      → /eks-d-xpress/infra/ami/{arch}/{k8s-version}
4. EksDXpressControlPlaneStack  → Lambdas read SSM params from steps 2+3
```

Steps 2 and 3 write SSM parameters that step 4 reads at deploy time:

| SSM Path | Written By | Read By |
|----------|-----------|---------|
| `/eks-d-xpress/infra/network/vpc-id` | Infra stack | Control plane |
| `/eks-d-xpress/infra/launch-template/{arch}/{pricing}` | Infra stack | Control plane |
| `/eks-d-xpress/infra/ami/{arch}/{k8s-version}` | `register-amis` | Control plane (tenant-service) |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-1` | Target deployment region |
| `AWS_PROFILE` | — | AWS CLI profile (when mounting `~/.aws`) |
| `EKS_DX_K8S_VERSIONS` | `1.35,1.36` | Kubernetes versions to register AMIs for |

## Dockerfile

```dockerfile
FROM public.ecr.aws/amazoncorretto/amazoncorretto:25.0.3-al2023-headless

# System dependencies
RUN dnf install -y nodejs22 npm unzip tar gzip findutils && dnf clean all

# AWS CLI v2
RUN curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# AWS CDK CLI + Helm
RUN npm install -g aws-cdk \
    && curl -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

WORKDIR /opt/eks-dx

# Pre-synthesized CDK stacks (from GitHub releases)
COPY infra/cdk.out ./infra/cdk.out
COPY control-plane/cdk.out ./control-plane/cdk.out

# AMI manifest
COPY ami-manifest.json ./ami-manifest.json

# Helm charts
COPY helm/ ./helm/

# CLI binary (architecture-matched at build time)
COPY eks-dx-cli ./bin/eks-dx
RUN chmod +x ./bin/eks-dx

# Orchestrator
COPY deploy.sh ./deploy.sh
RUN chmod +x ./deploy.sh

ENV PATH="/opt/eks-dx/bin:${PATH}"

ENTRYPOINT ["/opt/eks-dx/deploy.sh"]
CMD ["--help"]
```

## Build Pipeline

The bundle image is built by this repository (`eks-d-xpress`) in a GitHub Actions workflow that:

1. Downloads release artifacts from `eks-d-xpress-control-plane` and `eks-d-xpress-infra`
2. Downloads `ami-manifest.json` from the latest `eks-d-xpress` release
3. Stages everything into the Docker build context
4. Builds multi-arch images (linux/amd64 + linux/arm64)
5. Pushes to GHCR as `ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:{tag}`

See `.github/workflows/bundle-release.yml` for implementation.

## Golden AMI Manifest Format

```json
{
  "1.35": {
    "arm64": { "us-east-1": "ami-0abc...", "eu-west-1": "ami-0def..." },
    "x86_64": { "us-east-1": "ami-0123...", "eu-west-1": "ami-0fed..." }
  }
}
```

## Prerequisites for Customers

1. **AWS Account** with admin-level IAM permissions (or scoped for CDK)
2. **Docker** installed (any version supporting `--platform`)
3. **AWS credentials** — either:
   - `~/.aws/credentials` + `~/.aws/config` (mounted read-only)
   - Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`)
   - IAM role on EC2 (pass `--network=host` to inherit instance metadata)

## Multi-Architecture

Published as a manifest list:
- `linux/amd64` — x86_64 workstations and CI runners
- `linux/arm64` — Apple Silicon Macs and Graviton instances

Docker pulls the correct architecture automatically.

## Versioning

Tags follow the project release convention:
- `ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:v1.0.3` — pinned
- `ghcr.io/plasticity-of-cloud/eks-d-xpress-bundle:latest` — rolling

Each release bundles specific versions of all components:
- Control-plane CDK + Lambda zips (from control-plane release)
- Infra CDK (from infra release)
- AMI manifest (from eks-d-xpress release)
- CLI binary (from control-plane release)
- Helm charts (from control-plane release)
