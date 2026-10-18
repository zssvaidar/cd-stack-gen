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
    key          = "dev/network.tfstate"
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

module "vpc" {
  source = "../../../modules/vpc"

  name     = "dev"
  cidr     = "10.10.0.0/16"
  az_count = 2
}
