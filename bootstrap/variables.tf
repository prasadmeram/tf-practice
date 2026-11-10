variable "account_id" {
  description = "The 12-digit ID of the prod AWS account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region for the state bucket and your workloads."
  type        = string
}

variable "github_org" {
  description = "GitHub org or user that owns the repo, exactly as it appears on GitHub (case-sensitive)."
  type        = string
}

variable "github_repo" {
  description = "Repository name, exactly as it appears on GitHub (case-sensitive)."
  type        = string
}

variable "github_environment" {
  description = "Name of the GitHub Actions environment that gates applies."
  type        = string
  default     = "prod"
}

variable "use_github_environment" {
  description = <<-EOT
    true  = only jobs running in the GitHub environment above can assume the apply role (recommended).
    false = any job on the main branch can assume it. Use this only if your GitHub plan
            doesn't support environments on private repos (GitHub Free).
  EOT
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "Globally unique name for the state bucket. Defaults to tfstate-<account>-<region>."
  type        = string
  default     = null
}

variable "admin_principal_arn_patterns" {
  description = <<-EOT
    Human principals allowed to read/write state (for this bootstrap run and break-glass).
    If empty, defaults to the IAM Identity Center "AdministratorAccess" permission set.
    This MUST match the role you're using to run the bootstrap, or you'll lock yourself out of
    the state bucket. (The account root user can always delete the bucket policy to recover.)
  EOT
  type        = list(string)
  default     = []
}

# CHECK vs prod: only the name was visible in the screenshots; description/default inferred.
variable "app_iam_path" {
  description = "IAM path the apply role may create roles, instance profiles and policies under."
  type        = string
  default     = "/app/"
}
