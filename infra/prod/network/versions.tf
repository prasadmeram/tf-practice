terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }

  # Fill in bucket and kms_key_id from the bootstrap `backend_config_snippets` output.
  backend "s3" {
    bucket       = "tfstate-029633610112-ap-south-1"
    key          = "prod/network/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:ap-south-1:029633610112:key/381bddf4-57b6-40c2-8eff-096f80edf7d4"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  # Refuses to run if credentials belong to any other account.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Environment = "prod"
      Stack       = "network"
      ManagedBy   = "terraform"
    }
  }
}
