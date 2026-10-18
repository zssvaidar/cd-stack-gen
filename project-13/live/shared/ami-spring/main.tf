# Spring Boot image: project-14/spring-app as a jar on Corretto 21 behind Caddy :80, Grafana
# Alloy - ami-scripts/spring.sh. Launched by live/<env>/spring.
#
# One image per layer (live/shared/ami-<image>/), each with its own state, so each builds,
# rebuilds and is destroyed on its own. Shared by every environment: built once, launched in
# dev and then prod, so prod runs exactly the image that was tried in dev.
#
# The script fetches the app from this repo's git (APP_SOURCE, default GitHub) at app_ref. The ami
# module only rebuilds when the script, app_ref, the base AMI or the Packer template change -
# a new commit on the same branch is not one of those. To rebake for new code, apply with a
# new app_ref (a tag), or force it:
#   ./run.sh shared ami-spring apply -replace=module.ami.terraform_data.build
#
# The temporary Packer builder runs in dev's first public subnet - it only needs a public,
# IGW-routed subnet for the duration of the build.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key          = "shared/ami-spring.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "project-13"
      Environment = "shared"
      Purpose     = "shared"
      ManagedBy   = "terraform"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "state_bucket" {
  description = "Set by run.sh (TF_VAR_state_bucket)."
  type        = string
}

variable "app_ref" {
  description = "Branch or tag of this repo the image is built from (git clone --branch, so not a commit sha). Changing it rebuilds the image."
  type        = string
  default     = "master"
}

data "terraform_remote_state" "dev_network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "dev/network.tfstate"
    region = var.region
  }
}

locals {
  ami_scripts = "${path.root}/../../../ami-scripts"
  tags = {
    Project   = "project-13"
    ManagedBy = "terraform"
  }
}

module "ami" {
  source = "../../../modules/ami"

  name             = "spring"
  provision_script = "${local.ami_scripts}/spring.sh"
  provision_env    = ["APP_REF=${var.app_ref}"]
  # t3.medium: the Maven build (and its tests) runs a JVM next to the build's own.
  instance_type = "t3.medium"
  subnet_id     = data.terraform_remote_state.dev_network.outputs.public_subnet_ids[0]
  region        = var.region
  tags          = merge(local.tags, { Role = "spring" })
}

output "ami_id" {
  value = module.ami.ami_id
}

output "ami_name" {
  value = module.ami.ami_name
}
