# Offline - mock provider, no AWS credentials.
#   cd modules/nat && terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name                = "test-nat"
  ami_id              = "ami-0123456789abcdef0"
  vpc_id              = "vpc-0123456789abcdef0"
  vpc_cidr            = "10.10.0.0/16"
  public_subnet_ids   = ["subnet-pub-a", "subnet-pub-c"]
  app_route_table_ids = ["rtb-app-a", "rtb-app-c"]
}

run "single_nat_serves_every_az" {
  command = apply

  assert {
    condition     = length(module.instances.instance_ids) == 1
    error_message = "one NAT instance by default"
  }

  assert {
    condition     = aws_route.app_default[*].route_table_id == ["rtb-app-a", "rtb-app-c"]
    error_message = "every app route table should get a default route"
  }

  assert {
    condition     = alltrue([for r in aws_route.app_default : r.network_interface_id == module.instances.primary_network_interface_ids[0]])
    error_message = "both routes should point at the one NAT instance's ENI"
  }
}

run "one_per_az" {
  command = apply

  variables {
    instance_count = 2
  }

  assert {
    condition     = aws_route.app_default[*].network_interface_id == module.instances.primary_network_interface_ids
    error_message = "app route table i should point at NAT instance i (same AZ)"
  }

  assert {
    condition     = length(module.instances.public_ips) == 2
    error_message = "one Elastic IP per NAT instance"
  }
}

run "rejects_more_instances_than_azs" {
  command = plan

  variables {
    instance_count = 3
  }

  expect_failures = [var.instance_count]
}
