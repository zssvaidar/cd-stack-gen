variable "name" {
  description = "Name prefix, e.g. \"dev-nat\"."
  type        = string
}

variable "ami_id" {
  description = "An egress-gateway image (ami-scripts/egress-gateway.sh) - IP forwarding + masquerade baked in, applied at boot."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "Allowed in to the NAT instances (everything from inside the VPC)."
  type        = string
}

variable "public_subnet_ids" {
  description = "From modules/vpc - in azs order."
  type        = list(string)
}

variable "app_route_table_ids" {
  description = "From modules/vpc - in azs order. Each gets a 0.0.0.0/0 route through a NAT instance."
  type        = list(string)
}

variable "instance_count" {
  description = "1 = one shared NAT instance; length(public_subnet_ids) = one per AZ."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= length(var.public_subnet_ids)
    error_message = "instance_count must be between 1 and the number of public subnets (one per AZ at most)."
  }
}

variable "instance_type" {
  description = "t3/t4g burstable is fine for light egress; network bandwidth scales with size."
  type        = string
  default     = "t3.micro"
}

variable "tags" {
  type    = map(string)
  default = {}
}
