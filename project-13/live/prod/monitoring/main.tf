# Monitoring host for prod: Grafana :3000, Mimir :9009 (metrics), Loki :3100 (logs), from
# shared/ami-grafana (ami-scripts/grafana.sh). Every prod app layer (laravel, spring, csharp, go)
# reads this layer's private IP and points its Alloy at it, so apply this one first.
#
# Mimir and Loki have no authentication - inbound is the VPC only, and so is Grafana: reach it
# with an SSM port forward (see the grafana_port_forward output) or put a load balancer in front
# later. The admin password is generated on first boot into /etc/grafana/admin.env.
#
# Lives in an app subnet like the apps it watches; needs nothing from the internet at runtime.

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
    key          = "prod/monitoring.tfstate"
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
    key    = "shared/ami-grafana.tfstate"
    region = var.region
  }
}

locals {
  network = data.terraform_remote_state.network.outputs
  ami     = data.terraform_remote_state.ami.outputs
}

module "monitoring" {
  source = "../../../modules/instance"

  name           = "prod-monitoring"
  ami_id         = local.ami.ami_id
  vpc_id         = local.network.vpc_id
  subnet_ids     = [local.network.app_subnet_ids[0]]
  instance_count = 1
  # Mimir + Loki + Grafana side by side want 4 GB
  instance_type = "t3.medium"
  # 30 days of metrics, 14 days of logs (see project-14/monitoring/{mimir,loki}/config.yml)
  root_volume_size = 30

  ingress_rules = [
    {
      description = "Mimir remote-write from Alloy on every instance in the VPC"
      protocol    = "tcp"
      from_port   = 9009
      to_port     = 9009
      cidr_blocks = [local.network.vpc_cidr]
    },
    {
      description = "Loki push from Alloy on every instance in the VPC"
      protocol    = "tcp"
      from_port   = 3100
      to_port     = 3100
      cidr_blocks = [local.network.vpc_cidr]
    },
    {
      description = "Grafana from inside the VPC (a load balancer later, or an SSM port forward)"
      protocol    = "tcp"
      from_port   = 3000
      to_port     = 3000
      cidr_blocks = [local.network.vpc_cidr]
    },
  ]

  # The image's own Alloy already points at 127.0.0.1 - this only adds the env label.
  user_data = <<-EOT
    #cloud-config
    write_files:
      - path: /etc/alloy/endpoint.env
        content: |
          MONITORING_HOST=127.0.0.1
          ENVIRONMENT=prod
  EOT

  tags = {
    Role = "monitoring"
  }
}

output "instance_id" {
  value = module.monitoring.instance_ids[0]
}

output "private_ip" {
  description = "What every prod app instance's Alloy sends to."
  value       = module.monitoring.private_ips[0]
}

output "security_group_id" {
  value = module.monitoring.security_group_id
}

output "grafana_port_forward" {
  description = "Run locally, then open http://localhost:3000 (user admin; password: sudo cat /etc/grafana/admin.env over an SSM session)."
  value       = "aws ssm start-session --target ${module.monitoring.instance_ids[0]} --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=3000"
}
