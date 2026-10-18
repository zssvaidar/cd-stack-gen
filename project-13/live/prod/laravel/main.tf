# Laravel (project-14/laravel-app) on php-fpm behind Caddy, from shared/ami-laravel (ami-scripts/laravel.sh).
# Caddy on :80 from inside the VPC only (a load balancer later); health check /health/ready.
#
# Alloy on the instance ships metrics and logs to prod/monitoring - its private IP goes into
# /etc/alloy/endpoint.env via user_data, so apply prod/monitoring first. A new monitoring IP (or
# AMI) replaces the instance: instances here are immutable, nothing is patched in place.
#
# No RDS in project-13 yet, so Laravel uses the instance's own SQLite file - data is lost whenever
# the instance is replaced (new AMI, changed user_data). For a database, add to user_data:
#   - path: /etc/laravel-app/app.env
#     content: |
#       DB_CONNECTION=mysql
#       DB_HOST=...
#       RUN_MIGRATIONS=true
# (and get DB_PASSWORD from SSM rather than putting it here - user_data ends up in state).

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
    key          = "prod/laravel.tfstate"
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
    key    = "shared/ami-laravel.tfstate"
    region = var.region
  }

  # the image layer may already be gone when this one is destroyed - without a default, even
  # `destroy` fails with "Unsupported attribute". On apply a null AMI just fails at the
  # instance, so build the shared/ami-* layer first.
  defaults = {
    ami_id = null
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

  name       = "prod-laravel"
  ami_id     = local.ami.ami_id
  vpc_id     = local.network.vpc_id
  subnet_ids = local.network.app_subnet_ids
  # one per AZ, like prod/app
  instance_count = 2
  # php-fpm, Caddy and Alloy
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
    Role = "laravel"
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
