module "vpc_endpoints" {
  #checkov:skip=CKV_TF_1:Exact registry version pinned; Dependabot proposes upgrades as reviewed PRs
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.7.3"

  vpc_id = module.vpc.vpc_id

  # Only needed once you add interface endpoints.
  create_security_group      = length(var.interface_endpoints) > 0
  security_group_name_prefix = "${var.name}-vpc-endpoints-"
  security_group_description = "HTTPS from inside the VPC to interface endpoints"
  security_group_rules = {
    https_from_vpc = {
      description = "HTTPS from the VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  # Interface endpoints get an ENI in each private subnet (one per AZ).
  subnet_ids = module.vpc.private_subnets

  endpoints = merge(
    {
      # Free. Keeps S3 traffic (including Amazon Linux package repos) off the NAT.
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
        tags            = { Name = "${var.name}-s3" }
      }
    },
    {
      for svc in var.interface_endpoints : svc => {
        service             = svc
        private_dns_enabled = true
        tags                = { Name = "${var.name}-${svc}" }
      }
    },
  )
}
