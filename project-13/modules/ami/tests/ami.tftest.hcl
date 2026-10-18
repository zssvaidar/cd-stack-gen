# Offline, plan only - an apply would run the real `packer build`. Checks what decides when a
# rebuild happens; the build itself is Packer's (validate it with `packer validate`).
#   cd modules/ami && terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id   = "ami-0al2023latest00000"
      name = "al2023-ami-2023.9.20251014.0-kernel-6.12-x86_64"
    }
  }
}

variables {
  name             = "test"
  provision_script = "../../ami-scripts/example.sh"
  subnet_id        = "subnet-aaa"
  region           = "ap-northeast-1"
}

run "default_base_is_al2023" {
  command = plan

  assert {
    condition     = length(data.aws_ami.al2023) == 1 && output.base_ami_id == "ami-0al2023latest00000"
    error_message = "with no base_ami_id, the latest AL2023 lookup should be used"
  }

  assert {
    condition     = terraform_data.build.triggers_replace.script_sha == filesha256("../../ami-scripts/example.sh")
    error_message = "the provision script's content should be a rebuild trigger"
  }
}

run "pinned_base" {
  command = plan

  variables {
    base_ami_id = "ami-0pinned0000000000"
  }

  assert {
    condition     = length(data.aws_ami.al2023) == 0 && terraform_data.build.triggers_replace.base_ami_id == "ami-0pinned0000000000"
    error_message = "a pinned base_ami_id should skip the lookup and be the trigger"
  }
}
