variable "name" {
  description = "Name prefix, e.g. \"dev-vault\" - instance, bucket prefix, KMS alias."
  type        = string
}

variable "ami_id" {
  description = "A docker-vault image (ami-scripts/docker_vault.sh)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Where the one instance runs - a private app subnet (needs outbound to KMS via NAT; S3 goes through the VPC's gateway endpoint)."
  type        = string
}

variable "allowed_cidrs" {
  description = "Who can reach Vault on :8200."
  type        = list(string)
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "region" {
  type = string
}

variable "kms_deletion_window_days" {
  description = "How long a destroyed unseal key can still be cancelled (aws kms cancel-key-deletion). After that the vault's data is unrecoverable."
  type        = number
  default     = 30
}

variable "noncurrent_version_days" {
  description = "How long overwritten/deleted objects in the storage bucket are kept - the window to roll back a bad write."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
