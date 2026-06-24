# Packer Migration Design

> ⚠️ **Historical — completed.** `ami-builder/main.tf` (Terraform) has been replaced by
> `ami-builder/eks-d-xpress.pkr.hcl` (Packer). This document describes the migration
> rationale and is kept for reference only.

## Problem with the current approach

`ami-builder/main.tf` uses Terraform to build AMIs via `null_resource` + SSH
provisioners + `local-exec` polling loops. This works but misuses Terraform:

- Terraform tracks state for long-lived infrastructure; AMIs are build artifacts.
  The state file ends up referencing a builder EC2 that no longer exists.
- AMI creation requires manual polling loops (`for i in $(seq 1 60)`) instead
  of a native wait.
- Every build requires a `terraform destroy` pass just to clean up the builder.
- If the build fails mid-way, the state is dirty and must be manually repaired.

HashiCorp Packer's `amazon-ebs` builder handles all of this natively.

---

## What changes

Only the orchestration layer changes. All shell scripts are reused as-is.

```
ami-builder/
├── eks-d-xpress.pkr.hcl          ← replaces main.tf + variables.tf
└── scripts/                ← unchanged
    ├── install.sh
    └── discover-eks-d.sh
```

`build.sh` replaces `terraform init/apply/destroy` with `packer build`.

---

## Packer HCL structure

### `ami-builder/eks-d-xpress.pkr.hcl`

```hcl
packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "aws_region"          { type = string }
variable "arch"                { type = string  default = "x86_64" }
variable "instance_type"       { type = string  default = "m6i.xlarge" }
variable "kubernetes_version"  { type = string  default = "1.35" }
variable "ami_version"         { type = string }

locals {
  ami_arch = var.arch == "arm64" ? "arm64" : "x86_64"
}

source "amazon-ebs" "eks_dx" {
  region        = var.aws_region
  instance_type = var.instance_type

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023*-${local.ami_arch}"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ami_name        = "eks-dx-${local.ami_arch}-${var.ami_version}"
  ami_description = "EKS-DX with Karpenter - ${var.ami_version}"

  ssh_username = "ec2-user"

  # IMDSv2
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  # Store AMI ID in SSM after build
  run_tags = { Name = "eks-dx-builder-${var.arch}" }
}

build {
  sources = ["source.amazon-ebs.eks_dx"]

  # Upload setup scripts
  provisioner "file" {
    source      = "${path.root}/../eks-d-setup"
    destination = "/tmp/eks-d-setup"
  }

  provisioner "file" {
    source      = "${path.root}/scripts"
    destination = "/tmp/scripts"
  }

  # Run install
  provisioner "shell" {
    inline = [
      "chmod +x /tmp/scripts/*.sh",
      "export KUBERNETES_VERSION=${var.kubernetes_version}",
      "sudo -E bash /tmp/scripts/install.sh"
    ]
  }

  # Write AMI ID to SSM
  post-processor "shell-local" {
    inline = [
      "aws ssm put-parameter --name /eks-dx/ami/${local.ami_arch} --value $PACKER_BUILD_NAME --type String --overwrite --region ${var.aws_region} || true"
    ]
  }
}
```

> Note: Packer exposes the built AMI ID as `$PACKER_BUILD_NAME` is not correct —
> use a `manifest` post-processor to capture the AMI ID, then a `shell-local`
> to write it to SSM. See implementation note below.

### Capturing the AMI ID for SSM

Packer doesn't expose the AMI ID directly in `shell-local`. The clean pattern:

```hcl
  post-processor "manifest" {
    output     = "/tmp/packer-manifest.json"
    strip_path = true
  }

  post-processor "shell-local" {
    inline = [
      "AMI_ID=$(python3 -c \"import json; d=json.load(open('/tmp/packer-manifest.json')); print(d['builds'][-1]['artifact_id'].split(':')[-1])\")",
      "aws ssm put-parameter --name /eks-dx/ami/${local.ami_arch} --value $AMI_ID --type String --overwrite --region ${var.aws_region}",
      "echo 'AMI stored at SSM: /eks-dx/ami/${local.ami_arch} -> '$AMI_ID"
    ]
  }
```

---

## Updated `build.sh`

Replace the Terraform block with:

```bash
packer init "${AMI_BUILDER_DIR}/eks-d-xpress.pkr.hcl"

packer build \
  -var "aws_region=${AWS_REGION}" \
  -var "arch=${ARCH}" \
  -var "instance_type=${INSTANCE_TYPE}" \
  -var "kubernetes_version=${KUBERNETES_VERSION:-1.35}" \
  -var "ami_version=${AMI_VERSION}" \
  "${AMI_BUILDER_DIR}/eks-d-xpress.pkr.hcl"
```

No `terraform init`, no `terraform destroy`, no state file, no key pair management
(Packer creates a temporary key pair internally).

---

## Mapping: current Terraform → Packer

| Terraform resource / block              | Packer equivalent                        |
|-----------------------------------------|------------------------------------------|
| `data.aws_ami.al2023`                   | `source_ami_filter` in source block      |
| `aws_security_group.builder`            | Packer creates/destroys automatically    |
| `aws_instance.builder`                  | `source "amazon-ebs"` block              |
| `null_resource.wait_for_instance`       | Built-in (Packer waits for SSH)          |
| `null_resource.install` (file)          | `provisioner "file"`                     |
| `null_resource.install` (remote-exec)   | `provisioner "shell"`                    |
| `null_resource.create_ami` (stop+image) | Built-in (Packer stops + snapshots)      |
| `null_resource.create_ami` (poll loop)  | Built-in (Packer waits for availability) |
| `null_resource.create_ami` (ssm write)  | `post-processor "shell-local"`           |
| `terraform destroy`                     | Not needed — Packer terminates builder   |
| `eks-dx-tfstate-*/ami-builder/...`      | No state file                            |
| Temporary key pair in `build.sh`        | Packer manages internally                |

---

## Files to delete after migration

```
ami-builder/main.tf
ami-builder/variables.tf
ami-builder/backend.tf   (if exists)
```

---

## Prerequisites

```bash
# Install Packer (pin to a specific version)
wget https://releases.hashicorp.com/packer/1.11.2/packer_1.11.2_linux_amd64.zip
unzip packer_1.11.2_linux_amd64.zip
sudo mv packer /usr/local/bin/

# Install amazon plugin (done automatically by packer init)
packer init ami-builder/eks-d-xpress.pkr.hcl
```
