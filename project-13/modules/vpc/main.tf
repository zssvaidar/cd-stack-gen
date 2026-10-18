# Three tiers per AZ, same idea as project-11's bastion/app/db split but spread across
# az_count AZs from the start (project-12 had to bolt on "standby" subnets for RDS/ALB because
# project-11's subnets were all created without an explicit AZ):
#
#   public  10.x.0.0/24,  10.x.1.0/24, ...   IGW-routed - ALBs, NAT Gateways, bastion
#   app     10.x.10.0/24, 10.x.11.0/24, ...  private - ECS tasks / EC2, outbound via NAT
#   db      10.x.20.0/24, 10.x.21.0/24, ...  private, no internet route at all - RDS

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  public_offset = 0
  app_offset    = 10
  db_offset     = 20

  nat_count = {
    none   = 0
    single = 1
    per_az = var.az_count
  }[var.nat_mode]
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

# Take over the VPC's default security group and strip every rule from it, so anything
# launched without an explicit SG gets no access at all rather than the default allow-all
# between members.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-locked" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-igw" })
}

# --------------------------------------------------
# Subnets
# --------------------------------------------------

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr, 8, local.public_offset + count.index)

  # nothing gets a public IP just by landing here - an ALB/NAT brings its own
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "app" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr, 8, local.app_offset + count.index)

  tags = merge(var.tags, {
    Name = "${var.name}-app-${local.azs[count.index]}"
    Tier = "app"
  })
}

resource "aws_subnet" "db" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr, 8, local.db_offset + count.index)

  tags = merge(var.tags, {
    Name = "${var.name}-db-${local.azs[count.index]}"
    Tier = "db"
  })
}

# --------------------------------------------------
# Public routing
# --------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-public"
    Tier = "public"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --------------------------------------------------
# NAT (managed NAT Gateway, not project-11's NAT instance)
# --------------------------------------------------

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

# --------------------------------------------------
# App routing - one route table per AZ, so per_az NAT can send each AZ through its own gateway
# --------------------------------------------------

resource "aws_route_table" "app" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-app-${local.azs[count.index]}"
    Tier = "app"
  })
}

resource "aws_route" "app_nat" {
  count = local.nat_count > 0 ? var.az_count : 0

  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.nat_mode == "per_az" ? count.index : 0].id
}

resource "aws_route_table_association" "app" {
  count = var.az_count

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# --------------------------------------------------
# DB routing - local VPC traffic only, no default route
# --------------------------------------------------

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-db"
    Tier = "db"
  })
}

resource "aws_route_table_association" "db" {
  count = var.az_count

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# --------------------------------------------------
# S3 gateway endpoint (free)
# --------------------------------------------------

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.app[*].id, [aws_route_table.db.id])

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}
