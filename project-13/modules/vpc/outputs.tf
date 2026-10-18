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
  description = "One per AZ, in azs order - the NAT instance layer adds its 0.0.0.0/0 route to these."
  value       = aws_route_table.app[*].id
}

output "db_route_table_id" {
  value = aws_route_table.db.id
}
