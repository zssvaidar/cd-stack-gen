# One Vault server (ami-scripts/docker_vault.sh image) with:
#   - an S3 bucket as its storage backend
#   - a KMS key for auto-unseal - no unseal keys to type in after every restart
#   - an instance role that can reach exactly that bucket and that key
#
# Single instance on purpose: Vault's S3 backend has no HA support. All state lives in the
# bucket, so the instance itself is disposable - replace it (new AMI, other AZ) and the new one
# comes up with the same data, unsealed by KMS.

data "aws_caller_identity" "current" {}

# --------------------------------------------------
# Storage - Vault encrypts everything it writes with its own barrier key; SSE here is on top
# --------------------------------------------------

resource "aws_s3_bucket" "storage" {
  bucket_prefix = "${var.name}-storage-"

  # deliberately false: destroying the bucket destroys every secret in it. Empty it by hand if
  # you really mean it.
  force_destroy = false

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "storage" {
  bucket = aws_s3_bucket.storage.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "storage" {
  bucket = aws_s3_bucket.storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
  }
}

# --------------------------------------------------
# Auto-unseal key. Losing it = losing the vault: the data in S3 can't be unsealed without it.
# --------------------------------------------------

resource "aws_kms_key" "unseal" {
  description             = "${var.name} Vault auto-unseal"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days

  tags = var.tags
}

resource "aws_kms_alias" "unseal" {
  name          = "alias/${var.name}-unseal"
  target_key_id = aws_kms_key.unseal.key_id
}

# --------------------------------------------------
# Instance role permissions - this bucket and this key only
# --------------------------------------------------

data "aws_iam_policy_document" "vault" {
  statement {
    sid       = "StorageBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.storage.arn]
  }

  statement {
    sid       = "StorageObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.storage.arn}/*"]
  }

  statement {
    sid       = "AutoUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.unseal.arn]
  }
}

# inline on the role modules/instance creates (SSM access included) - attached by role name
# rather than via iam_policy_arns, whose for_each needs ARNs known at plan time
resource "aws_iam_role_policy" "vault" {
  name   = "vault-storage-and-unseal"
  role   = module.instance.iam_role_name
  policy = data.aws_iam_policy_document.vault.json
}

# --------------------------------------------------
# The server
# --------------------------------------------------

locals {
  # read by vault-render.sh (ExecStartPre of vault.service) - restart picks it up immediately
  # instead of waiting for the unit's own retry
  user_data = <<-EOT
    #!/bin/bash
    set -e
    cat > /etc/vault/vault.env <<'ENV'
    VAULT_S3_BUCKET=${aws_s3_bucket.storage.bucket}
    VAULT_KMS_KEY_ID=${aws_kms_key.unseal.key_id}
    AWS_REGION=${var.region}
    ENV
    systemctl restart vault.service
  EOT
}

module "instance" {
  source = "../instance"

  name           = var.name
  ami_id         = var.ami_id
  instance_type  = var.instance_type
  vpc_id         = var.vpc_id
  subnet_ids     = [var.subnet_id]
  instance_count = 1

  ingress_rules = [{
    description = "Vault API/UI"
    protocol    = "tcp"
    from_port   = 8200
    to_port     = 8200
    cidr_blocks = var.allowed_cidrs
  }]

  user_data = local.user_data

  tags = var.tags
}
