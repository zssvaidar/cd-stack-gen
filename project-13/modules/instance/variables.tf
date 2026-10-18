variable "name" {
  description = "Name prefix - instances are tagged <name>-1, <name>-2, ..."
  type        = string
}

variable "ami_id" {
  description = "Image to launch, e.g. module.ami.ami_id. A new id replaces the instances (immutable rollout)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Instances are spread over these round-robin: instance i goes in subnet_ids[i % length]. Pass one subnet per AZ to get one instance per AZ."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must contain at least one subnet."
  }
}

variable "instance_count" {
  type    = number
  default = 1
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ingress_rules" {
  description = "Inbound rules for the instances' own security group. Empty = no inbound at all (reach it via SSM instead)."
  type = list(object({
    description = string
    protocol    = string # "tcp", "udp", "icmp" or "-1" for all
    from_port   = number
    to_port     = number
    cidr_blocks = list(string)
  }))
  default = []
}

variable "extra_security_group_ids" {
  description = "Other security groups to attach alongside the module's own."
  type        = list(string)
  default     = []
}

variable "associate_public_ip" {
  description = "Auto-assigned public IP (changes on stop/start). Only works in a public subnet."
  type        = bool
  default     = false
}

variable "elastic_ip" {
  description = "Attach a fixed Elastic IP to each instance instead - e.g. a NAT instance whose egress IP gets allowlisted elsewhere. Public subnet only."
  type        = bool
  default     = false
}

variable "source_dest_check" {
  description = "false for anything that forwards traffic not addressed to itself - NAT instances, routers."
  type        = bool
  default     = true
}

variable "ssm_access" {
  description = "Give the instances an IAM role with AmazonSSMManagedInstanceCore, so `aws ssm start-session` works without SSH or any inbound rule."
  type        = bool
  default     = true
}

variable "iam_policy_arns" {
  description = "Extra managed policies for the instance role (only used when ssm_access = true, which creates the role). ARNs must be known at plan time (e.g. AWS-managed); for a policy created in the same apply, attach it to iam_role_name instead (see modules/vault)."
  type        = list(string)
  default     = []
}

variable "key_name" {
  description = "EC2 key pair for SSH. null = none (SSM only)."
  type        = string
  default     = null
}

variable "user_data" {
  description = "Boot-time script/cloud-config. Changing it replaces the instances."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "GiB. null = the AMI's own size."
  type        = number
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
