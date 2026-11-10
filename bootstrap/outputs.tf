output "state_bucket_name" {
  value = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  value = aws_kms_key.state.arn
}

output "plan_role_arn" {
  description = "Set as GitHub repository variable AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as GitHub repository variable AWS_APPLY_ROLE_ARN"
  value       = aws_iam_role.apply.arn
}

output "workload_permissions_boundary_arn" {
  description = "Every aws_iam_role in your app Terraform must set permissions_boundary to this"
  value       = aws_iam_policy.workload_boundary.arn
}

output "backend_config_snippets" {
  description = "Paste each into the matching versions.tf (bootstrap uses key = bootstrap/terraform.tfstate)"
  value = {
    for stack in ["bootstrap", "network", "app"] : stack => <<-EOT
      backend "s3" {
        bucket       = "${aws_s3_bucket.state.bucket}"
        key          = "${stack == "bootstrap" ? "bootstrap" : "prod/${stack}"}/terraform.tfstate"
        region       = "${var.region}"
        encrypt      = true
        kms_key_id   = "${aws_kms_key.state.arn}"
        use_lockfile = true
      }
    EOT
  }
}

output "github_repository_variables" {
  description = "Create these under Settings → Secrets and variables → Actions → Variables"
  value = {
    AWS_ACCOUNT_ID     = var.account_id
    AWS_REGION         = var.region
    AWS_PLAN_ROLE_ARN  = aws_iam_role.plan.arn
    AWS_APPLY_ROLE_ARN = aws_iam_role.apply.arn
  }
}
