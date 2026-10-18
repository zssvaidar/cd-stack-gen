# Read by later layers (ecs, rds, ...) via terraform_remote_state on this state key.

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "azs" {
  value = module.vpc.azs
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "app_subnet_ids" {
  value = module.vpc.app_subnet_ids
}

output "db_subnet_ids" {
  value = module.vpc.db_subnet_ids
}

output "public_route_table_id" {
  value = module.vpc.public_route_table_id
}

output "app_route_table_ids" {
  value = module.vpc.app_route_table_ids
}

output "db_route_table_id" {
  value = module.vpc.db_route_table_id
}
