packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

locals {
  # sortable, collision-free by construction - two builds in the same second would need the
  # same name/env_type/purpose too, at which point they're the same build anyway
  build_timestamp = formatdate("YYYYMMDD'T'hhmmss", timestamp())
  ami_name        = "${var.purpose}-${var.name}-${var.env_type}-${local.build_timestamp}"

  # applied to the AMI itself (`tags`) and its backing snapshot (`snapshot_tags`) identically -
  # both need to carry these for manage_ami.sh's delete() to find them by tag later
  common_tags = {
    Purpose     = var.purpose
    Name        = var.name
    Environment = var.env_type
  }
}

source "amazon-ebs" "ami" {
  region          = var.aws_region
  source_ami      = var.base_ami_id
  instance_type   = var.instance_type
  ami_name        = local.ami_name
  ami_description = "Built by manage_ami.sh (Packer) for ${var.name}/${var.env_type}, Purpose=${var.purpose}"

  # encrypt the root volume by default - the AMI is meant to be handed to
  # manage_instance_ami.sh for real deploys, not just kept as a build artifact
  encrypt_boot = true

  subnet_id = var.subnet_id

  # no security_group_id (manage_ami.sh's default, BUILD_SG=temporary): Packer creates its own
  # temporary SG allowing tcp/22 only from the public IP of the machine running `packer build`,
  # and deletes it with the builder - no manual port-22 rule, and the shared tier SGs are never
  # touched. A given security_group_id (BUILD_SG=tier) is used as-is instead.
  security_group_id                         = var.security_group_id != "" ? var.security_group_id : null
  temporary_security_group_source_public_ip = var.security_group_id == ""
  associate_public_ip_address = var.assign_public_ip
  iam_instance_profile        = var.instance_profile_name != "" ? var.instance_profile_name : null

  # no ssh_keypair_name set - Packer generates a temporary ed25519 keypair for just this
  # build and tears it down again afterward, so the builder's SSH access never depends on
  # (or extends) any persistent key from project-11/manage_keys.sh
  ssh_username            = "ec2-user"
  temporary_key_pair_type = "ed25519"

  tags            = local.common_tags
  snapshot_tags   = local.common_tags
  run_tags        = merge(local.common_tags, { Name = "ami-builder-${var.name}-${var.env_type}" })
  run_volume_tags = local.common_tags
}

build {
  sources = ["source.amazon-ebs.ami"]

  # Packer's SSH connection comes up the moment sshd is reachable, which is well before
  # cloud-init's own boot-time dnf/rpm work (repo metadata refresh, package updates) has
  # finished - the actual provisioning script starting at the same time then collides with it
  # on the rpm lock ("can't create transaction lock ... Resource temporarily unavailable").
  # Block on cloud-init finishing first, so by the time the real script's dnf/rpm calls run,
  # nothing else on the box still has the lock.
  provisioner "shell" {
    inline = ["cloud-init status --wait"]
  }

  provisioner "shell" {
    script = var.provision_script

    # unlike the old cloud-init/user-data approach (which ran as root automatically), Packer's
    # shell provisioner connects as $ssh_username and runs the script as that user with no
    # elevation by default - ami-scripts/*.sh scripts write to root-owned paths (/etc/yum.repos.d,
    # systemd units, package installs), so run the whole script under sudo rather than requiring
    # every script author to remember to prefix each command themselves. Amazon Linux's ec2-user
    # has passwordless sudo out of the box.
    execute_command = "chmod +x {{ .Path }} && sudo {{ .Vars }} {{ .Path }}"
  }

  # packer build's own stdout isn't meant to be parsed - the manifest post-processor writes a
  # stable JSON file manage_ami.sh reads the resulting AMI ID back out of via jq
  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
    custom_data = {
      ami_name = local.ami_name
    }
  }
}
