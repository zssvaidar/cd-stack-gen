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

run "single_nat_shared_by_every_az" {
  command = apply

  variables {
    nat_mode = "single"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "single mode should create exactly one NAT Gateway"
  }

  assert {
    condition     = length(aws_route.app_nat) == 2
    error_message = "every app route table should get a default route"
  }

  assert {
    condition     = alltrue([for r in aws_route.app_nat : r.nat_gateway_id == aws_nat_gateway.this[0].id])
    error_message = "every app route should point at the one NAT Gateway"
  }
}

run "per_az_nat" {
  command = apply

  variables {
    nat_mode = "per_az"
    az_count = 3
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "per_az mode should create one NAT Gateway per AZ"
  }

  assert {
    condition     = [for r in aws_route.app_nat : r.nat_gateway_id] == aws_nat_gateway.this[*].id
    error_message = "each AZ's app route should point at its own AZ's NAT Gateway"
  }
}

run "no_nat" {
  command = plan

  variables {
    nat_mode = "none"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_route.app_nat) == 0
    error_message = "none mode should create no NAT Gateway and no app default route"
  }
}

run "rejects_non_slash16" {
  command = plan

  variables {
    cidr = "10.10.0.0/20"
  }

  expect_failures = [var.cidr]
}
