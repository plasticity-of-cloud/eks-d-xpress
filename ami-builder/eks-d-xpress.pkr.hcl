packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "aws_region"         { type = string }
variable "kubernetes_version" {
  type    = string
  default = "1.35"
}
variable "ami_version"        { type = string }
variable "project_name" {
  type    = string
  default = "eks-d-xpress-infra"
}
variable "build_type" {
  type    = string
  default = "internal"
  # "release"  — direct upstream registries (no pull-through cache); used for GitHub releases
  # "internal" — pull-through cache in private ECR; used for internal/customer builds
}

source "amazon-ebs" "x86_64" {
  region        = var.aws_region
  instance_type = "c6a.large"

  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023*-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ami_name        = "eks-d-xpress-x86_64-${var.ami_version}"
  ami_description = "EKS-D-Xpress ${var.kubernetes_version} x86_64 - ${var.ami_version}"
  ssh_username    = "ec2-user"

  iam_instance_profile = "eks-d-xpress-packer-builder"

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

  run_tags = {
    Name     = "eks-d-xpress-builder-x86_64"
    Platform = "eks-d-xpress"
    ManagedBy = "Packer"
  }

  tags = {
    Name              = "eks-d-xpress-x86_64-${var.ami_version}"
    Platform          = "eks-d-xpress"
    Project           = var.project_name
    KubernetesVersion = var.kubernetes_version
    ManagedBy         = "Packer"
  }
}

source "amazon-ebs" "arm64" {
  region        = var.aws_region
  instance_type = "c6g.large"

  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023*-arm64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ami_name        = "eks-d-xpress-arm64-${var.ami_version}"
  ami_description = "EKS-D-Xpress ${var.kubernetes_version} arm64 - ${var.ami_version}"
  ssh_username    = "ec2-user"

  iam_instance_profile = "eks-d-xpress-packer-builder"

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

  run_tags = {
    Name      = "eks-d-xpress-builder-arm64"
    Platform  = "eks-d-xpress"
    ManagedBy = "Packer"
  }

  tags = {
    Name              = "eks-d-xpress-arm64-${var.ami_version}"
    Platform          = "eks-d-xpress"
    Project           = var.project_name
    KubernetesVersion = var.kubernetes_version
    ManagedBy         = "Packer"
  }
}

build {
  sources = ["source.amazon-ebs.x86_64", "source.amazon-ebs.arm64"]

  provisioner "file" {
    source      = "${path.root}/../eks-d-setup"
    destination = "/tmp/eks-d-setup"
  }

  provisioner "file" {
    source      = "${path.root}/scripts"
    destination = "/tmp/scripts"
  }

  provisioner "file" {
    source      = "${path.root}/../node-pools"
    destination = "/tmp/node-pools"
  }

  provisioner "file" {
    source      = "${path.root}/files/ecr-credential-provider-${source.name == "x86_64" ? "amd64" : "arm64"}"
    destination = "/tmp/ecr-credential-provider"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/scripts/*.sh /tmp/scripts/components/*.sh",
      "export KUBERNETES_VERSION=${var.kubernetes_version}",
      "export BUILD_TYPE=${var.build_type}",
      "sudo -E bash /tmp/scripts/install.sh"
    ]
  }

  # Generate SBOM of the installed filesystem before the AMI is snapshotted
  provisioner "shell" {
    inline = [
      "sudo syft dir:/ --exclude './**/proc/**' --exclude './**/sys/**' --exclude './**/dev/**' --exclude './**/tmp/**' -o spdx-json > /tmp/sbom.spdx.json",
      "echo '✓ SBOM generated'"
    ]
  }

  provisioner "file" {
    source      = "/tmp/sbom.spdx.json"
    destination = "${path.root}/sbom-${source.name}-${var.ami_version}.spdx.json"
    direction   = "download"
  }

  provisioner "file" {
    source      = "/tmp/sbom.spdx.json"
    destination = "${path.root}/sbom-${source.name}-${var.ami_version}.spdx.json"
    direction   = "download"
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }

  post-processor "shell-local" {
    inline = [
      # Push AMI IDs to SSM and write a clean manifest entry per build
      "python3 -c \"\nimport json, sys\nbuilds = json.load(open('packer-manifest.json'))['builds']\nentries = []\nfor b in builds:\n    region, ami_id = b['artifact_id'].split(':')\n    arch = b['name']\n    entries.append({'kubernetes_version': '${var.kubernetes_version}', 'arch': arch, 'region': region, 'ami_id': ami_id})\n    import subprocess\n    subprocess.run(['aws','ssm','put-parameter','--name',f'/eks-d-xpress/infra/ami/{arch}/${var.kubernetes_version}','--value',ami_id,'--type','String','--overwrite','--region',region], check=True)\n    print(f'Stored /eks-d-xpress/infra/ami/{arch}/${var.kubernetes_version} -> {ami_id}')\njson.dump(entries, open('ami-manifest-entries.json','w'), indent=2)\n\""
    ]
  }
}
