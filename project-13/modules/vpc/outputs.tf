output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "azs" {
  value = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "db_subnet_ids" {
  value = aws_subnet.db[*].id
}

output "public_route_table_id" {
  value = aws_route_table.public.id
}

output "app_route_table_ids" {
  value = aws_route_table.app[*].id
}

output "db_route_table_id" {
  value = aws_route_table.db.id
}

output "nat_public_ips" {
  description = "Egress IPs the app tier's outbound traffic comes from - allowlist these on anything external."
  value       = aws_eip.nat[*].public_ip
}
