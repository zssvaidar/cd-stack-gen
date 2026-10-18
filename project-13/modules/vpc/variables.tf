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

variable "nat_mode" {
  description = <<-EOT
    Outbound internet for the app tier:
      none   - no NAT; app subnets reach only the VPC (and S3 via the gateway endpoint)
      single - one NAT Gateway in the first AZ, shared by every app subnet (cheaper, one AZ is a single point of failure)
      per_az - one NAT Gateway per AZ, each app subnet routes through its own AZ's (survives an AZ outage)
  EOT
  type        = string
  default     = "single"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_mode)
    error_message = "nat_mode must be one of: none, single, per_az."
  }
}

variable "enable_s3_endpoint" {
  description = "Add a free S3 gateway endpoint to the private route tables (ECR image layers come from S3, so this also cuts NAT traffic)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto every resource (on top of the provider's default_tags)."
  type        = map(string)
  default     = {}
}
