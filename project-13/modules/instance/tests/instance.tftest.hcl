# Offline - mock provider, no AWS credentials.
#   cd modules/instance && terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name       = "test"
  ami_id     = "ami-0123456789abcdef0"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-aaa", "subnet-bbb"]
}

run "defaults" {
  command = plan

  assert {
    condition     = length(aws_instance.this) == 1
    error_message = "one instance by default"
  }

  assert {
    condition     = aws_instance.this[0].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be enforced"
  }

  assert {
    condition     = aws_instance.this[0].root_block_device[0].encrypted == true
    error_message = "root volume must be encrypted"
  }

  assert {
    condition     = length(aws_iam_instance_profile.this) == 1 && contains(keys(aws_iam_role_policy_attachment.this), "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore")
    error_message = "ssm_access defaults on - role with AmazonSSMManagedInstanceCore"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 0
    error_message = "no inbound rules unless asked for"
  }

  assert {
    condition     = length(aws_eip.this) == 0
    error_message = "no Elastic IP unless asked for"
  }
}

run "spread_round_robin" {
  command = plan

  variables {
    instance_count = 3
  }

  assert {
    condition     = aws_instance.this[*].subnet_id == ["subnet-aaa", "subnet-bbb", "subnet-aaa"]
    error_message = "instances should be spread over subnet_ids round-robin"
  }

  assert {
    condition     = aws_instance.this[*].tags.Name == ["test-1", "test-2", "test-3"]
    error_message = "instances should be named <name>-1..N"
  }
}

run "nat_style" {
  command = apply

  variables {
    instance_count    = 2
    source_dest_check = false
    elastic_ip        = true
    ssm_access        = false
    ingress_rules = [{
      description = "everything from the VPC"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      cidr_blocks = ["10.10.0.0/16"]
    }]
  }

  assert {
    condition     = alltrue([for i in aws_instance.this : i.source_dest_check == false])
    error_message = "source/dest check should be off"
  }

  assert {
    condition     = [for e in aws_eip.this : e.instance] == aws_instance.this[*].id
    error_message = "one Elastic IP per instance"
  }

  assert {
    condition     = length(aws_iam_role.this) == 0 && length(aws_iam_instance_profile.this) == 0
    error_message = "no IAM role when ssm_access = false"
  }

  assert {
    condition     = one(values(aws_vpc_security_group_ingress_rule.this)).cidr_ipv4 == "10.10.0.0/16" && one(values(aws_vpc_security_group_ingress_rule.this)).from_port == null
    error_message = "all-protocol rule from the VPC CIDR, with no port range"
  }
}

run "rejects_empty_subnets" {
  command = plan

  variables {
    subnet_ids = []
  }

  expect_failures = [var.subnet_ids]
}
