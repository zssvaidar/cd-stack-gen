# Offline - mock provider, no AWS credentials.
#   cd modules/vault && terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      bucket = "dev-vault-storage-20261018"
      arn    = "arn:aws:s3:::dev-vault-storage-20261018"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      key_id = "11111111-2222-3333-4444-555555555555"
      arn    = "arn:aws:kms:ap-northeast-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
  }
}

variables {
  name          = "dev-vault"
  ami_id        = "ami-0123456789abcdef0"
  vpc_id        = "vpc-0123456789abcdef0"
  subnet_id     = "subnet-app-a"
  allowed_cidrs = ["10.10.0.0/16"]
  region        = "ap-northeast-1"
}

run "server" {
  command = apply

  assert {
    condition     = length(module.instance.instance_ids) == 1
    error_message = "exactly one Vault instance - the S3 backend has no HA"
  }

  assert {
    condition     = strcontains(local.user_data, "VAULT_S3_BUCKET=dev-vault-storage-20261018") && strcontains(local.user_data, "VAULT_KMS_KEY_ID=11111111-2222-3333-4444-555555555555") && strcontains(local.user_data, "AWS_REGION=ap-northeast-1")
    error_message = "user-data should hand the bucket, key and region to vault-render.sh"
  }

  assert {
    condition     = output.vault_addr == "https://${module.instance.private_ips[0]}:8200"
    error_message = "vault_addr should be https on the instance's private IP"
  }
}

run "least_privilege" {
  command = plan

  assert {
    condition     = aws_s3_bucket.storage.force_destroy == false
    error_message = "the storage bucket must not be force-destroyable"
  }

  assert {
    condition     = aws_kms_key.unseal.enable_key_rotation == true && aws_kms_key.unseal.deletion_window_in_days == 30
    error_message = "unseal key: rotation on, 30-day deletion window"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.storage.block_public_policy == true && aws_s3_bucket_public_access_block.storage.restrict_public_buckets == true
    error_message = "storage bucket must block public access"
  }
}
