# Self-managed NAT for the app tier: NAT instances (from the egress-gateway image) in the
# public subnets, and every app route table's 0.0.0.0/0 pointed at one of them.
#
#   instance_count = 1               every AZ's app subnet goes out through the one instance
#   instance_count = length(public)  one per AZ, each AZ's app subnet through its own
#
# Index i of public_subnet_ids and app_route_table_ids is the same AZ (modules/vpc builds both
# in azs order), and modules/instance places instance i in public_subnet_ids[i] - so route
# table i -> instance i % count keeps traffic in its own AZ whenever there's one there.

module "instances" {
  source = "../instance"

  name           = var.name
  ami_id         = var.ami_id
  instance_type  = var.instance_type
  vpc_id         = var.vpc_id
  subnet_ids     = var.public_subnet_ids
  instance_count = var.instance_count

  # forwards traffic that isn't addressed to itself
  source_dest_check = false

  # fixed egress IP - what external services see the app tier's traffic coming from
  elastic_ip = true

  ingress_rules = [{
    description = "anything from inside the VPC - traffic to NAT out"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [var.vpc_cidr]
  }]

  tags = var.tags
}

resource "aws_route" "app_default" {
  count = length(var.app_route_table_ids)

  route_table_id         = var.app_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.instances.primary_network_interface_ids[count.index % var.instance_count]
}
