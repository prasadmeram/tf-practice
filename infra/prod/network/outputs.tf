output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "database_subnet_ids" {
  value = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  value = module.vpc.database_subnet_group_name
}

output "nat_gateway_ids" {
  value = module.vpc.natgw_ids
}

output "egress_ips" {
  description = "Every outbound IP prod can use. Give all of these to anyone who allowlists you."
  value       = aws_eip.nat[*].public_ip
}
