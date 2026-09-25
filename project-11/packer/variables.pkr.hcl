variable "aws_region" {
  type        = string
  description = "Region to build in - matches $AWS_REGION from the orchestrator's state file."
}

variable "purpose" {
  type        = string
  description = "Purpose tag - matches $PURPOSE, ties this build to the rest of project-11's state."
}

variable "name" {
  type        = string
  description = "Human name for what this AMI is, e.g. 'myapp'."
}

variable "env_type" {
  type        = string
  description = "Environment type, e.g. production/staging/dev - picks which ami-scripts/<env_type>.sh ran to build this."
}

variable "provision_script" {
  type        = string
  description = "Absolute path to the shell provisioner script that defines what's baked into the image."
}

variable "base_ami_id" {
  type        = string
  description = "Base AMI to build from. Always resolved to a real ami-xxxx by manage_ami.sh before packer build runs (defaults to the latest Amazon Linux 2023 via SSM Parameter Store if BASE_AMI_ID isn't set) - no fallback lookup here, so the same AMI resolution logic isn't duplicated in two places."
}

variable "subnet_id" {
  type        = string
  description = "Subnet for the builder instance - from $STATE_FILE's network create output, picked by $TIER."
}

variable "security_group_id" {
  type        = string
  default     = ""
  description = "Security group for the builder instance. Empty (the default via manage_ami.sh, BUILD_SG=temporary) = Packer creates a temporary SG allowing SSH only from this machine's public IP and deletes it afterwards. Set = used as-is, and must then allow inbound SSH (22) from wherever `packer build` runs."
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "instance_profile_name" {
  type        = string
  default     = ""
  description = "IAM instance profile for the builder (from $STATE_FILE's ssm create output). Optional - useful if the provisioning script itself needs AWS API access."
}

variable "assign_public_ip" {
  type        = bool
  default     = true
  description = "The subnets project-11/manage_network.sh creates don't auto-assign public IPs and this network has no NAT gateway, so without one the builder has a route to the internet gateway but no way to actually use it - package downloads in the provisioning script would hang. Set false only if a NAT gateway exists instead."
}
