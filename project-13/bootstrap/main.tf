# The S3 bucket every other root module in project-13 keeps its state in. Chicken-and-egg:
# this one can't store its own state in a bucket it hasn't created yet, so it stays on local
# state (bootstrap/terraform.tfstate, gitignored). Losing that file is harmless - the bucket
# just stops being managed by Terraform; `terraform import aws_s3_bucket.state <name>` (plus
# the other resources below) brings it back.
#
# Locking uses S3's native lockfile (backend `use_lockfile = true`, Terraform >= 1.10) - no
# DynamoDB table needed.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "project-13"
      Purpose   = "tfstate"
      ManagedBy = "terraform"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "bucket_name" {
  description = "Override the state bucket name. Defaults to cd-stack-gen-tfstate-<account-id>, which is what run.sh assumes too."
  type        = string
  default     = null
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = coalesce(var.bucket_name, "cd-stack-gen-tfstate-${data.aws_caller_identity.current.account_id}")
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

# every state write keeps the previous version - the undo button for a bad apply or a corrupted state
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# old state versions pile up forever otherwise
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}
