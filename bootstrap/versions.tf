terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }

  # STEP 2: after the first `terraform apply`, uncomment this block, fill it in
  # from the `backend_config_snippets` output (the "bootstrap" entry), and run `terraform init -migrate-state`.
  
  backend "s3" {
    bucket       = "tfstate-029633610112-ap-south-1"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:ap-south-1:029633610112:key/381bddf4-57b6-40c2-8eff-096f80edf7d4"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  # Hard stop if your credentials point at the wrong account.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "bootstrap"
      Repo      = "${var.github_org}/${var.github_repo}"
    }
  }
}
