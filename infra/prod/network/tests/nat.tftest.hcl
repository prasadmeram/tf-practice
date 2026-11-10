# Plan-only tests with a mocked AWS provider: no credentials, nothing created.
# Checks the subnet layout and that switching NAT mode behaves as documented.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/app/prod-vpc-flow-logs" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-south-1:123456789012:log-group:/aws/vpc-flow-log/prod" }
  }
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
}

run "single_nat" {
  command = plan
  assert {
    condition     = local.public_subnets == ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
    error_message = "public subnets wrong: ${jsonencode(local.public_subnets)}"
  }
  assert {
    condition     = local.private_subnets == ["10.20.16.0/20", "10.20.32.0/20", "10.20.48.0/20"]
    error_message = "private subnets wrong: ${jsonencode(local.private_subnets)}"
  }
  assert {
    condition     = local.database_subnets == ["10.20.64.0/24", "10.20.65.0/24", "10.20.66.0/24"]
    error_message = "db subnets wrong: ${jsonencode(local.database_subnets)}"
  }
  assert {
    condition     = length(aws_eip.nat) == 3
    error_message = "expected 3 preallocated EIPs"
  }
  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "expected 1 NAT"
  }
  assert {
    condition     = length(module.vpc.private_route_table_ids) == 1
    error_message = "expected 1 private route table"
  }
}

run "per_az_nat" {
  command = plan
  variables {
    nat_gateway_mode = "per_az"
  }
  assert {
    condition     = length(module.vpc.natgw_ids) == 3
    error_message = "expected 3 NATs"
  }
  assert {
    condition     = length(module.vpc.private_route_table_ids) == 3
    error_message = "expected 3 private route tables"
  }
  assert {
    condition     = length(aws_eip.nat) == 3
    error_message = "EIP count must not change when switching"
  }
}

run "no_prealloc_single" {
  command = plan
  variables {
    preallocate_nat_eips = false
  }
  assert {
    condition     = length(aws_eip.nat) == 1
    error_message = "expected 1 EIP"
  }
}
