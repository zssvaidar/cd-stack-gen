# Node.js app image: nginx :80 -> node on 127.0.0.1:3000, smoke-tested at build time
# (ami-scripts/nodejs.sh). Launched by live/<env>/app.
#
# One image per layer (live/shared/ami-<image>/), each with its own state, so each builds,
# rebuilds and is destroyed on its own. Shared by every environment: built once, launched in
# dev and then prod, so prod runs exactly the image that was tried in dev.
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
    key          = "shared/ami-nodejs.tfstate"
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

  name             = "nodejs"
  provision_script = "${local.ami_scripts}/nodejs.sh"
  subnet_id        = data.terraform_remote_state.dev_network.outputs.public_subnet_ids[0]
  region           = var.region
  tags             = merge(local.tags, { Role = "nodejs" })
}

output "ami_id" {
  value = module.ami.ami_id
}

output "ami_name" {
  value = module.ami.ami_name
}
