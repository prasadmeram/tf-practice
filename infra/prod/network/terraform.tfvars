# Non-secret settings only.
account_id = "029633610112"
region     = "ap-south-1"

name     = "prod"
vpc_cidr = "10.20.0.0/16"
azs      = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]

# Switch to "per_az" when you want NAT high availability. See README before you do.
nat_gateway_mode     = "single"
preallocate_nat_eips = true

# Add interface endpoints when you need them (billed per AZ per hour), e.g.:
# interface_endpoints = ["ssm", "ssmmessages", "ec2messages", "sts", "secretsmanager", "logs"]
interface_endpoints = []

flow_log_retention_days = 7 # PRACTICE: prod uses 90

workload_permissions_boundary_arn = "arn:aws:iam::029633610112:policy/ci/workload-permissions-boundary"
