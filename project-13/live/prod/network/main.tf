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
    key          = "prod/network.tfstate"
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

module "vpc" {
  source = "../../../modules/vpc"

  name     = "prod"
  cidr     = "10.20.0.0/16"
  az_count = 2

  # one NAT Gateway per AZ, so losing one AZ doesn't cut outbound internet for the other
  nat_mode = "per_az"
}
