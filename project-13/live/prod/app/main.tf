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
    key          = "prod/app.tfstate"
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
    key    = "shared/ami-nodejs.tfstate"
    region = var.region
  }
}

locals {
  network = data.terraform_remote_state.network.outputs
  ami     = data.terraform_remote_state.ami.outputs
}

# The Node.js app (ami-scripts/nodejs_caddy.sh: Caddy on :80 -> node on 127.0.0.1:3000), in prod's
# private app subnets - spread one per AZ. No public IP and only port 80 from inside the VPC;
# reach it through a load balancer (later layer) or an SSM port forward (see README).
# Needs prod/nat applied first: the SSM agent has to reach AWS's endpoints to register.
module "app" {
  source = "../../../modules/instance"

  name           = "prod-nodejs"
  ami_id         = local.ami.ami_id
  vpc_id         = local.network.vpc_id
  subnet_ids     = local.network.app_subnet_ids
  instance_count = 2
  instance_type  = "t3.micro"

  ingress_rules = [{
    description = "http from inside the VPC (load balancer, other tiers)"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = [local.network.vpc_cidr]
  }]

  tags = {
    Role = "nodejs"
  }
}

output "instance_ids" {
  value = module.app.instance_ids
}

output "private_ips" {
  value = module.app.private_ips
}

output "security_group_id" {
  value = module.app.security_group_id
}
