output "instance_ids" {
  value = aws_instance.this[*].id
}

output "availability_zones" {
  value = aws_instance.this[*].availability_zone
}

output "private_ips" {
  value = aws_instance.this[*].private_ip
}

output "public_ips" {
  description = "Elastic IPs if elastic_ip = true, otherwise the auto-assigned public IPs (empty strings if none)."
  value       = var.elastic_ip ? aws_eip.this[*].public_ip : aws_instance.this[*].public_ip
}

output "primary_network_interface_ids" {
  description = "Route targets - e.g. a NAT instance's ENI is what an app route table's 0.0.0.0/0 points at."
  value       = aws_instance.this[*].primary_network_interface_id
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "iam_role_name" {
  value = var.ssm_access ? aws_iam_role.this[0].name : null
}
