# Images shared by every environment - built once, launched in dev and prod alike, so prod runs
# exactly the image that was tried in dev. One module block per image; each builds from one
# ami-scripts/*.sh (symlinked from project-11).
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
    key          = "shared/ami.tfstate"
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

module "egress_gateway" {
  source = "../../../modules/ami"

  name             = "egress-gateway"
  provision_script = "${local.ami_scripts}/egress-gateway.sh"
  subnet_id        = data.terraform_remote_state.dev_network.outputs.public_subnet_ids[0]
  region           = var.region
  tags             = merge(local.tags, { Role = "egress-gateway" })
}

output "egress_gateway_ami_id" {
  value = module.egress_gateway.ami_id
}

output "egress_gateway_ami_name" {
  value = module.egress_gateway.ami_name
}
