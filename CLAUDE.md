# tf-practice

Terraform → AWS (ap-south-1) repo for prod, deployed by GitHub Actions through OIDC. Mirrors the user's prod bootstrap exactly.
Three stacks, each with its own state in S3 (native lockfile, KMS-encrypted):

- `bootstrap/`: run once from a laptop. State bucket, KMS key, GitHub OIDC provider, plan/apply roles, workload permissions boundary, apply-role guardrails.
- `infra/prod/network/`: VPC (3 AZs), public/private/database subnets, NAT (`single` + 3 pre-allocated EIPs), S3 gateway + optional interface endpoints, flow logs.
- `infra/prod/app/`: EC2 + SGs + example IAM role, optional ALB/RDS. Finds the network **by name/tag**, never remote state.

Why things are the way they are: `docs/decisions.md`.

## Hard rules
- **Never run terraform, aws, or install commands.** The user runs everything themselves to learn it. Write code and print the commands. (`.claude/settings.json` also denies apply/destroy/import/state changes/migrate-state.)
- **IAM:** every `aws_iam_role` has `path = "/app/"` and `permissions_boundary = var.workload_permissions_boundary_arn`. Instance profiles and customer-managed policies also go under `/app/`. Anything else fails with `AccessDenied` on purpose.
- **Secrets** never go in code, tfvars or state. RDS uses `manage_master_user_password = true`. Other secrets: Secrets Manager by ARN, or write-only args (`password_wo`).
- **Data sources:** PR plans use the read-only role, which is denied secret values, account SSM params, DynamoDB items and S3 objects outside the state bucket. Public params such as `/aws/service/ami-amazon-linux-latest/...` work.
- **Plans always use `-lock=false`.** The plan role cannot write to the state bucket.
- **Network changes the app depends on** go in their own PR first; the app PR's plan only sees network resources that already exist.
- **Stateful resources:** `deletion_protection = true` + `prevent_destroy = true`. To delete something, change the code first.
- Don't rename the VPC `Name = "prod"` tag or the subnet `Tier` tags; the app stack looks them up.
- Pin GitHub Actions to full commit SHAs with a `# vX.Y.Z` comment. Terraform `~> 1.16.0`, AWS provider `~> 6.66`.

## Stack order
Apply: `bootstrap` → `network` → `app`. Removing: `app` → `network` → `bootstrap` (after turning protection off in code).

## Open items
- `bootstrap/github_oidc.tf` and `variables.tf` have `# CHECK vs prod` comments where screenshots of the prod file were missing (lines 267–279, 337–354, 412–415; `app_iam_path` default).
- Placeholders: `bootstrap/terraform.tfvars` (by hand); `REPLACE_*` in the stacks' `versions.tf`/`terraform.tfvars` and CODEOWNERS (by `scripts/configure.sh`).
