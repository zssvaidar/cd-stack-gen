variable "name" {
  description = "Prefix for every resource's Name tag, e.g. \"dev\" or \"prod\"."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR. Must be a /16 - subnets are carved out as /24s with cidrsubnet(cidr, 8, n)."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && endswith(var.cidr, "/16")
    error_message = "cidr must be a valid /16, e.g. 10.10.0.0/16."
  }
}

variable "az_count" {
  description = "How many Availability Zones to spread every tier across. 2 minimum - ALBs and RDS subnet groups both require it."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "enable_s3_endpoint" {
  description = "Add a free S3 gateway endpoint to the private route tables (ECR image layers come from S3, so image pulls skip the NAT instance)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto every resource (on top of the provider's default_tags)."
  type        = map(string)
  default     = {}
}
