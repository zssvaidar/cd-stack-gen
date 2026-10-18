output "vault_addr" {
  description = "VAULT_ADDR for clients inside the VPC (self-signed cert - see README for the CA)."
  value       = "https://${module.instance.private_ips[0]}:8200"
}

output "instance_id" {
  value = module.instance.instance_ids[0]
}

output "private_ip" {
  value = module.instance.private_ips[0]
}

output "security_group_id" {
  value = module.instance.security_group_id
}

output "storage_bucket" {
  value = aws_s3_bucket.storage.bucket
}

output "kms_key_arn" {
  value = aws_kms_key.unseal.arn
}

output "kms_alias" {
  value = aws_kms_alias.unseal.name
}
