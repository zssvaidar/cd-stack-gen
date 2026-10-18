# ASP.NET Core (project-14/csharp-app), self-contained behind Caddy, from shared/ami-csharp (ami-scripts/csharp.sh).
# Caddy on :80 from inside the VPC only (a load balancer later); health check /health/ready.
#
# Alloy on the instance ships metrics and logs to prod/monitoring - its private IP goes into
# /etc/alloy/endpoint.env via user_data, so apply prod/monitoring first. A new monitoring IP (or
# AMI) replaces the instance: instances here are immutable, nothing is patched in place.

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
    key          = "prod/csharp.tfstate"
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
    key    = "shared/ami-csharp.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "monitoring" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "prod/monitoring.tfstate"
    region = var.region
  }
}

locals {
  network    = data.terraform_remote_state.network.outputs
  ami        = data.terraform_remote_state.ami.outputs
  monitoring = data.terraform_remote_state.monitoring.outputs
}

module "app" {
  source = "../../../modules/instance"

  name       = "prod-csharp"
  ami_id     = local.ami.ami_id
  vpc_id     = local.network.vpc_id
  subnet_ids = local.network.app_subnet_ids
  # one per AZ, like prod/app
  instance_count = 2
  # ASP.NET Core and Alloy
  instance_type = "t3.small"

  ingress_rules = [{
    description = "http from inside the VPC (load balancer, other tiers)"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = [local.network.vpc_cidr]
  }]

  user_data = <<-EOT
    #cloud-config
    write_files:
      - path: /etc/alloy/endpoint.env
        content: |
          MONITORING_HOST=${local.monitoring.private_ip}
          ENVIRONMENT=prod
  EOT

  tags = {
    Role = "csharp"
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

output "health_check_path" {
  description = "For a load balancer target group in front of these instances (port 80)."
  value       = "/health/ready"
}
