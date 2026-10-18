# Bakes an AMI from one of ami-scripts/*.sh by running Packer (packer/ami.pkr.hcl) from a
# terraform_data resource - Terraform has no resource that runs a provisioning script and
# snapshots the result, and Packer already does that well (temporary builder, temporary SG and
# keypair, cleanup on failure). Terraform's part is deciding *when* to build and tracking the
# result:
#
#   - triggers_replace: the script's content, the base AMI, provision_env and the Packer
#     template itself. Change any of them and the next apply builds a new AMI.
#   - every build is tagged BuildId = terraform_data id; data.aws_ami looks it up by that tag,
#     so the AMI id lands in state like any other resource attribute.
#   - create_before_destroy: a rebuild registers the new AMI first, then the destroy-time
#     provisioner deregisters the old one and deletes its snapshots. Instances already running
#     from the old AMI are unaffected by the deregistration.
#
# Needs `packer` on PATH wherever terraform runs, plus the AWS credentials terraform uses
# (run.sh's set_root configures the default profile, which Packer picks up too).

data "aws_ami" "al2023" {
  count = var.base_ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  base_ami_id      = coalesce(var.base_ami_id, try(data.aws_ami.al2023[0].id, null))
  provision_script = abspath(var.provision_script)
  packer_dir       = abspath("${path.module}/packer")

  packer_vars = {
    aws_region            = var.region
    name                  = var.name
    provision_script      = local.provision_script
    provision_env         = var.provision_env
    base_ami_id           = local.base_ami_id
    subnet_id             = var.subnet_id
    instance_type         = var.instance_type
    instance_profile_name = var.instance_profile_name
    tags                  = var.tags
  }
}

resource "terraform_data" "build" {
  triggers_replace = {
    name         = var.name
    script_sha   = filesha256(local.provision_script)
    template_sha = filesha256("${local.packer_dir}/ami.pkr.hcl")
    base_ami_id  = local.base_ami_id
    env          = join("\n", var.provision_env)
  }

  # read back by the destroy provisioner, which can only see self
  input = {
    region = var.region
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      command -v packer >/dev/null || { echo "packer not found on PATH - https://developer.hashicorp.com/packer/install" >&2; exit 1; }

      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      varfile="$tmp/build.pkrvars.json"
      cat > "$varfile" <<'JSON'
      ${jsonencode(merge(local.packer_vars, { build_id = self.id }))}
      JSON

      packer init "${local.packer_dir}"
      packer validate -var-file="$varfile" "${local.packer_dir}"
      packer build -color=false -var-file="$varfile" "${local.packer_dir}"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      region="${self.input.region}"

      for ami in $(aws ec2 describe-images --region "$region" --owners self \
          --filters "Name=tag:BuildId,Values=${self.id}" \
          --query 'Images[].ImageId' --output text); do

          snapshots=$(aws ec2 describe-images --region "$region" --image-ids "$ami" \
              --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)

          echo "Deregistering $ami"
          aws ec2 deregister-image --region "$region" --image-id "$ami"

          for snap in $snapshots; do
              echo "Deleting snapshot $snap"
              aws ec2 delete-snapshot --region "$region" --snapshot-id "$snap"
          done
      done
    EOT
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_ami" "built" {
  owners = ["self"]

  filter {
    name   = "tag:BuildId"
    values = [terraform_data.build.id]
  }
}
