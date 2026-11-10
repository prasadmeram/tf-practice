variable "account_id" {
  description = "Prod AWS account ID."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "name" {
  description = "Name of the VPC. The app stack finds the VPC, subnets and DB subnet group by this name."
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = <<-EOT
    VPC range. Choose one that won't overlap with staging, CI, office VPN or any
    partner network you might peer with later. Changing it later means rebuilding the VPC.
  EOT
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16 (the subnet layout in main.tf assumes one)."
  }
}

variable "azs" {
  description = "Availability Zones to spread subnets across. Listed explicitly so they never change underneath you."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 3
    error_message = "This layout expects exactly 3 AZs."
  }
}

variable "nat_gateway_mode" {
  description = <<-EOT
    "single" = one NAT gateway in the first AZ (cheaper; if that AZ fails, private subnets
               lose outbound internet).
    "per_az" = one NAT gateway per AZ (highly available; three times the NAT hourly cost).
  EOT
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be \"single\" or \"per_az\"."
  }
}

variable "preallocate_nat_eips" {
  description = <<-EOT
    true  = allocate one Elastic IP per AZ now, even while running a single NAT gateway.
            Your outbound IPs are then fixed forever, so anyone allowlisting them gets all
            three up front and switching to per_az changes nothing for them.
    false = only allocate EIPs for the NAT gateways that exist.
    Idle EIPs are billed like any public IPv4 address.
  EOT
  type        = bool
  default     = true
}

variable "interface_endpoints" {
  description = <<-EOT
    AWS services to reach through interface VPC endpoints instead of NAT, e.g.
    ["ssm", "ssmmessages", "ec2messages", "sts", "secretsmanager", "logs"].
    Each one is billed per AZ per hour, so add them deliberately. The S3 gateway endpoint
    is always created (it's free).
  EOT
  type        = list(string)
  default     = []
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs."
  type        = number
  default     = 7 # PRACTICE: prod uses 90
}

variable "workload_permissions_boundary_arn" {
  description = "From the bootstrap output. Required on every IAM role this stack creates."
  type        = string
}
