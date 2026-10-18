# Driven by modules/ami (terraform_data + local-exec), not run by hand - same build as
# project-11/packer/ami.pkr.hcl, trimmed to the one way this project builds: a temporary SG
# (ssh only from the machine running packer) and a public IP, in a public subnet.

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type = string
}

variable "name" {
  type        = string
  description = "What this image is, e.g. egress-gateway - prefix of the AMI name."
}

variable "build_id" {
  type        = string
  description = "terraform_data id of the build - tagged as BuildId, which is how Terraform finds the AMI afterwards and deregisters it on destroy."
}

variable "provision_script" {
  type        = string
  description = "Absolute path to the ami-scripts/*.sh that defines what's baked in."
}

variable "provision_env" {
  type        = list(string)
  default     = []
  description = "KEY=VALUE pairs exported to the provision script. Not for secrets."
}

variable "base_ami_id" {
  type = string
}

variable "subnet_id" {
  type        = string
  description = "A public (IGW-routed) subnet - the builder gets a public IP and Packer SSHes to it directly."
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "instance_profile_name" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  build_timestamp = formatdate("YYYYMMDD'T'hhmmss", timestamp())
  ami_name        = "${var.name}-${local.build_timestamp}"

  # applied to the AMI and its snapshot identically - the destroy step finds both by BuildId
  common_tags = merge(var.tags, {
    Name    = var.name
    BuildId = var.build_id
  })
}

source "amazon-ebs" "ami" {
  region          = var.aws_region
  source_ami      = var.base_ami_id
  instance_type   = var.instance_type
  ami_name        = local.ami_name
  ami_description = "Built by project-13 modules/ami (Packer) from ${basename(var.provision_script)}"

  encrypt_boot = true

  subnet_id                                 = var.subnet_id
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true
  iam_instance_profile                      = var.instance_profile_name != "" ? var.instance_profile_name : null

  # imdsv2 on the builder too, same as the instances launched from the image
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  imds_support = "v2.0"

  ssh_username            = "ec2-user"
  temporary_key_pair_type = "ed25519"

  tags            = local.common_tags
  snapshot_tags   = local.common_tags
  run_tags        = merge(local.common_tags, { Name = "ami-builder-${var.name}" })
  run_volume_tags = local.common_tags
}

build {
  sources = ["source.amazon-ebs.ami"]

  # cloud-init's boot-time dnf work holds the rpm lock - wait it out before the real script
  # (see project-11/ami-scripts/README.md)
  provisioner "shell" {
    inline = ["cloud-init status --wait"]
  }

  provisioner "shell" {
    script           = var.provision_script
    environment_vars = var.provision_env

    # ami-scripts/*.sh are written to run as root
    execute_command = "chmod +x {{ .Path }} && sudo {{ .Vars }} {{ .Path }}"
  }
}
