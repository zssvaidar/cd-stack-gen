terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket/region are passed in by run.sh (-backend-config) - backend blocks can't take variables
  backend "s3" {
    key          = "dev/nat.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "project-13"
      Environment = "dev"
      Purpose     = "dev"
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

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "dev/network.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "ami" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "shared/ami-egress-gateway.tfstate"
    region = var.region
  }

  # the image layer may already be gone when this one is destroyed - without a default, even
  # `destroy` fails with "Unsupported attribute". On apply a null AMI just fails at the
  # instance, so build the shared/ami-* layer first.
  defaults = {
    ami_id = null
  }
}

locals {
  network = data.terraform_remote_state.network.outputs
  ami     = data.terraform_remote_state.ami.outputs
}

# Outbound internet for dev's app tier - NAT instances from the shared egress-gateway image.
module "nat" {
  source = "../../../modules/nat"

  name                = "dev-nat"
  ami_id              = local.ami.ami_id
  vpc_id              = local.network.vpc_id
  vpc_cidr            = local.network.vpc_cidr
  public_subnet_ids   = local.network.public_subnet_ids
  app_route_table_ids = local.network.app_route_table_ids

  # one shared NAT instance - an AZ outage cuts dev's outbound internet, acceptable for dev
  instance_count = 1
}

output "instance_ids" {
  value = module.nat.instance_ids
}

output "public_ips" {
  description = "dev's egress IPs - allowlist these on anything external the app tier calls."
  value       = module.nat.public_ips
}
