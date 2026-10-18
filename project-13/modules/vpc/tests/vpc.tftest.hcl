# Offline - mock_provider fakes every AWS call, so `terraform test` needs no credentials.
#   cd modules/vpc && terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-northeast-1"
    }
  }
}

variables {
  name = "test"
  cidr = "10.10.0.0/16"
}

run "subnet_layout" {
  command = plan

  assert {
    condition     = aws_subnet.public[*].cidr_block == ["10.10.0.0/24", "10.10.1.0/24"]
    error_message = "public subnets should be 10.10.0.0/24 and 10.10.1.0/24"
  }

  assert {
    condition     = aws_subnet.app[*].cidr_block == ["10.10.10.0/24", "10.10.11.0/24"]
    error_message = "app subnets should be 10.10.10.0/24 and 10.10.11.0/24"
  }

  assert {
    condition     = aws_subnet.db[*].cidr_block == ["10.10.20.0/24", "10.10.21.0/24"]
    error_message = "db subnets should be 10.10.20.0/24 and 10.10.21.0/24"
  }

  assert {
    condition     = length(distinct(aws_subnet.app[*].availability_zone)) == 2
    error_message = "app subnets must land in two distinct AZs"
  }
}

run "routing" {
  command = apply

  variables {
    az_count = 3
  }

  assert {
    condition     = length(aws_route_table.app) == 3
    error_message = "one app route table per AZ, so each AZ's NAT instance can be routed separately"
  }

  assert {
    condition     = aws_route.public_internet.route_table_id == aws_route_table.public.id && aws_route.public_internet.gateway_id == aws_internet_gateway.this.id
    error_message = "the public route table's default route should go via the IGW"
  }

  assert {
    condition     = toset(aws_vpc_endpoint.s3[0].route_table_ids) == toset(concat(aws_route_table.app[*].id, [aws_route_table.db.id]))
    error_message = "the S3 endpoint should be attached to every app route table and the db route table"
  }
}

run "rejects_non_slash16" {
  command = plan

  variables {
    cidr = "10.10.0.0/20"
  }

  expect_failures = [var.cidr]
}
