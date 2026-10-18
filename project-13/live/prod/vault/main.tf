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
    key          = "prod/vault.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "project-13"
      Environment = "prod"
      Purpose     = "prod"
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
    key    = "prod/network.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "ami" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "shared/ami-docker-vault.tfstate"
    region = var.region
  }
}

locals {
  network = data.terraform_remote_state.network.outputs
  ami     = data.terraform_remote_state.ami.outputs
}

# Vault for prod: one instance in the first private app subnet, S3 storage + KMS auto-unseal
# (modules/vault). Reachable on :8200 from inside the VPC only. Needs prod/nat applied first -
# KMS is reached through the NAT instance (S3 goes through the VPC's gateway endpoint).
module "vault" {
  source = "../../../modules/vault"

  name          = "prod-vault"
  ami_id        = local.ami.ami_id
  vpc_id        = local.network.vpc_id
  subnet_id     = local.network.app_subnet_ids[0]
  allowed_cidrs = [local.network.vpc_cidr]
  region        = var.region

  tags = {
    Role = "vault"
  }
}

output "vault_addr" {
  value = module.vault.vault_addr
}

output "instance_id" {
  value = module.vault.instance_id
}

output "storage_bucket" {
  value = module.vault.storage_bucket
}

output "kms_alias" {
  value = module.vault.kms_alias
}
