variable "name" {
  description = "What this image is, e.g. \"egress-gateway\" - AMI name prefix and Name tag."
  type        = string
}

variable "provision_script" {
  description = "Path to the ami-scripts/*.sh that defines what's baked into the image (e.g. \"$${path.root}/../../../ami-scripts/egress-gateway.sh\"). Editing the file triggers a rebuild."
  type        = string
}

variable "provision_env" {
  description = "KEY=VALUE pairs exported to the provision script on the builder (Packer environment_vars). Not for secrets - they end up in the build's command line and Terraform state."
  type        = list(string)
  default     = []
}

variable "subnet_id" {
  description = "Public (IGW-routed) subnet for the temporary builder instance - Packer SSHes to its public IP."
  type        = string
}

variable "base_ami_id" {
  description = "Base image to build from. null = latest Amazon Linux 2023 x86_64 - which means a newer AL2023 release shows up in plan as a rebuild; pin an ami-... here to stop that."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "Builder instance type. Only affects build speed, not what the AMI can run on (same architecture aside)."
  type        = string
  default     = "t3.micro"
}

variable "instance_profile_name" {
  description = "IAM instance profile for the builder - only needed if the provision script itself calls AWS APIs (e.g. reads from SSM/S3)."
  type        = string
  default     = ""
}

variable "region" {
  type = string
}

variable "tags" {
  description = "Tags for the AMI, its snapshot and the builder."
  type        = map(string)
  default     = {}
}
