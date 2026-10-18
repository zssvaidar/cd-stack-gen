output "instance_ids" {
  value = module.instances.instance_ids
}

output "public_ips" {
  description = "Elastic IPs - the app tier's outbound traffic comes from these; allowlist them on anything external."
  value       = module.instances.public_ips
}

output "private_ips" {
  value = module.instances.private_ips
}

output "security_group_id" {
  value = module.instances.security_group_id
}
