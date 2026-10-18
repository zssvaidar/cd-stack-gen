# N instances from one AMI, spread across the given subnets, each with:
#   - the module's own security group (ingress_rules in, everything out)
#   - IMDSv2 only and an encrypted root volume
#   - optionally an SSM-enabled instance role, an Elastic IP, source/dest check off
#
# Instances are immutable: a new ami_id or user_data replaces them rather than patching in
# place - build a new image (modules/ami) and apply.

locals {
  subnet_for = [for i in range(var.instance_count) : var.subnet_ids[i % length(var.subnet_ids)]]
}

# --------------------------------------------------
# Security group
# --------------------------------------------------

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "${var.name} instances"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = {
    for r in flatten([
      for rule in var.ingress_rules : [
        for cidr in rule.cidr_blocks : merge(rule, { cidr = cidr })
      ]
    ]) : "${r.protocol}-${r.from_port}-${r.to_port}-${r.cidr}" => r
  }

  security_group_id = aws_security_group.this.id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.protocol == "-1" ? null : each.value.from_port
  to_port           = each.value.protocol == "-1" ? null : each.value.to_port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --------------------------------------------------
# IAM - SSM Session Manager instead of SSH
# --------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  count = var.ssm_access ? 1 : 0

  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = var.ssm_access ? toset(concat(["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"], var.iam_policy_arns)) : toset([])

  role       = aws_iam_role.this[0].name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "this" {
  count = var.ssm_access ? 1 : 0

  name_prefix = "${var.name}-"
  role        = aws_iam_role.this[0].name

  tags = var.tags
}

# --------------------------------------------------
# Instances
# --------------------------------------------------

resource "aws_instance" "this" {
  count = var.instance_count

  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_for[count.index]
  vpc_security_group_ids      = concat([aws_security_group.this.id], var.extra_security_group_ids)
  associate_public_ip_address = var.associate_public_ip
  source_dest_check           = var.source_dest_check
  iam_instance_profile        = var.ssm_access ? aws_iam_instance_profile.this[0].name : null
  key_name                    = var.key_name

  user_data                   = var.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags        = merge(var.tags, { Name = "${var.name}-${count.index + 1}" })
  volume_tags = merge(var.tags, { Name = "${var.name}-${count.index + 1}" })

  # new AMI = new instance up before the old one goes, so e.g. a NAT route can move over
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eip" "this" {
  count = var.elastic_ip ? var.instance_count : 0

  domain   = "vpc"
  instance = aws_instance.this[count.index].id

  tags = merge(var.tags, { Name = "${var.name}-${count.index + 1}" })
}
