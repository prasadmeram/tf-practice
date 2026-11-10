locals {
  # Subnet layout inside the /16 (example values assume 10.20.0.0/16):
  #
  #   public    10.20.0.0/24   10.20.1.0/24   10.20.2.0/24    ALB + NAT only (251 IPs each)
  #   private   10.20.16.0/20  10.20.32.0/20  10.20.48.0/20   EC2 / app (4,091 IPs each)
  #   database  10.20.64.0/24  10.20.65.0/24  10.20.66.0/24   RDS, no internet route
  #   free      10.20.80.0 - 10.20.255.255                    room for CI runners, EKS, etc.
  public_subnets   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 1)]
  database_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 64 + i)]
}

# ---------------------------------------------------------------------------
# NAT Elastic IPs, managed outside the module so they survive NAT changes.
# These are your outbound IPs: losing one breaks any partner allowlist.
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  #checkov:skip=CKV2_AWS_19:These EIPs belong to NAT gateways, not EC2 instances

  count  = var.preallocate_nat_eips ? length(var.azs) : (var.nat_gateway_mode == "per_az" ? length(var.azs) : 1)
  domain = "vpc"

  tags = {
    Name = "${var.name}-nat-${var.azs[count.index]}"
  }

  lifecycle {
    prevent_destroy = false # PRACTICE: prod uses true
  }
}

module "vpc" {
  #checkov:skip=CKV_TF_1:Exact registry version pinned; Dependabot proposes upgrades as reviewed PRs
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  enable_dns_support      = true
  enable_dns_hostnames    = true # needed for private DNS on interface endpoints
  map_public_ip_on_launch = false

  # NAT: flip nat_gateway_mode to "per_az" later. NAT #1 and its IP stay put;
  # two more NAT gateways and route tables are added (see README).
  enable_nat_gateway     = true
  single_nat_gateway     = var.nat_gateway_mode == "single"
  one_nat_gateway_per_az = var.nat_gateway_mode == "per_az"
  reuse_nat_ips          = true
  external_nat_ip_ids    = aws_eip.nat[*].id

  # Database tier: its own route table with no internet or NAT route at all.
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  # Adopt the defaults and neuter them: the default security group gets zero rules,
  # so nothing that accidentally lands in it can talk to anything.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []
  manage_default_network_acl     = true
  manage_default_route_table     = true

  # Flow logs to CloudWatch, using the role in flow_logs.tf (path + boundary
  # required by the CI apply role).
  enable_flow_log                                 = true
  flow_log_destination_type                       = "cloud-watch-logs"
  flow_log_traffic_type                           = "ALL"
  flow_log_max_aggregation_interval               = 60
  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_name_suffix       = var.name
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days
  create_flow_log_cloudwatch_iam_role             = false
  flow_log_cloudwatch_iam_role_arn                = aws_iam_role.flow_logs.arn

  # The app stack looks subnets up by these tags.
  public_subnet_tags   = { Tier = "public" }
  private_subnet_tags  = { Tier = "private" }
  database_subnet_tags = { Tier = "database" }
}
