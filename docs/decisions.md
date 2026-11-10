# Decisions

Short ADR-style log. Newest at the bottom. Each entry: context → decision → consequence.

## 1. GitHub OIDC instead of AWS access keys
- **Context:** CI needs AWS access. Long-lived keys in GitHub secrets leak, never expire and are hard to rotate.
- **Decision:** GitHub's OIDC provider in IAM; workflows call `sts:AssumeRoleWithWebIdentity` and get 1-hour credentials.
- **Consequence:** No AWS secrets in GitHub at all. The four repo variables are not sensitive. Trust is scoped by the token's `sub` claim (repo + PR / branch / environment).

## 2. Separate plan and apply roles
- **Context:** PR plans run code from any branch. If that job could write to AWS, anyone who can open a PR could change prod.
- **Decision:** `github-terraform-plan` (read-only, assumable from PRs and `main`) and `github-terraform-apply` (write, assumable **only** from the `prod` GitHub environment; `use_github_environment = false` falls back to any job on `main`, for GitHub Free + private repos). The apply role gets AWS `PowerUserAccess` plus path-scoped IAM, and a guardrail policy that denies changing the CI roles, the boundary, the OIDC provider, the state bucket/key, and the audit logs (CloudTrail, GuardDuty, Config, Security Hub).
- **Consequence:** A PR's worst case is reading. Writing requires merging to `main` and a human approving the `prod` environment. The plan role is also denied secret values, account SSM parameters, DynamoDB items and S3 objects outside the state bucket, so a malicious `data` source in a PR can't exfiltrate them.

## 3. Permissions boundary + `/app/` path for workload IAM
- **Context:** The apply role must create IAM roles (flow logs, EC2). Unrestricted `iam:CreateRole` is admin in disguise: create a role with `AdministratorAccess`, then use it.
- **Decision:** The apply role can only write IAM under `/app/`, and only when the role carries `workload-permissions-boundary`. The boundary lives under `/ci/`, which the apply role can't edit, and removing a boundary is explicitly denied.
- **Consequence:** Every role in the stacks needs `path = "/app/"` and `permissions_boundary = var.workload_permissions_boundary_arn`, or you get `AccessDenied` (on purpose). A new AWS permission for workloads first means widening the boundary in bootstrap.

## 4. S3 native locking instead of DynamoDB
- **Context:** Terraform ≥ 1.10 can lock with a conditional write of `<key>.tflock` in the state bucket.
- **Decision:** `use_lockfile = true`, no DynamoDB table.
- **Consequence:** One fewer resource and permission set. The plan role has **no** write access to the bucket, so every plan runs with `-lock=false` (a plan never writes state). Only the apply role takes the lock. All stacks pin Terraform `~> 1.16.0` (CI uses 1.16.4).

## 5. Separate state per stack
- **Context:** One big state means every change plans and locks everything, and one bad apply can touch routing.
- **Decision:** `bootstrap`, `network`, `app` each have their own state key.
- **Consequence:** Small, fast plans and a small blast radius. Order matters: `network` before `app` on apply, and the reverse on teardown.

## 6. The app finds the network by tag, not remote state
- **Context:** `terraform_remote_state` couples the app to the network's state layout and needs read access to that state file. Hardcoded IDs rot.
- **Decision:** `data "aws_vpc"` by `Name = "prod"`, `data "aws_subnets"` by `Tier` tag, DB subnet group by name.
- **Consequence:** The app stack can't change the network at all. The tags are a contract: renaming `Name`/`Tier` in the network breaks the app plan (loudly, at plan time). A network change the app depends on must merge and apply first, because the app's PR plan only sees what already exists.
- **Related:** CI plans only the stacks a PR touches (all of them if workflows change), so a first PR that only creates the network doesn't fail the app plan.

## 7. Single NAT + pre-allocated EIPs (prod)
- **Context:** A NAT per AZ costs about 3× as much. Partners allow-list our egress IPs.
- **Decision:** Prod runs `nat_gateway_mode = "single"` with `preallocate_nat_eips = true`: 3 EIPs created outside the VPC module (`prevent_destroy` in prod) and passed in with `reuse_nat_ips`.
- **Consequence:** Losing ap-south-1a loses private egress until we switch to `per_az`. That switch only **adds** NAT 2/3 and route tables 2/3; NAT 1, its IP and route table 1 stay (proved by `tests/nat.tftest.hcl`). All 3 IPs can be allow-listed on day one. This is the default in `infra/prod/network`.

## 8. Interface endpoints off by default
- **Context:** Each interface endpoint costs ~$0.01/hr **per AZ** (~$22/mo for 3 AZs), and a typical SSM set is 6 of them.
- **Decision:** `interface_endpoints = []` by default, opt in per service. The S3 **gateway** endpoint is free and always on.
- **Consequence:** Without NAT or endpoints, private instances reach S3 (and so the Amazon Linux repos) but not SSM / STS / Secrets Manager. To use Session Manager, turn on NAT or the SSM endpoints.

## 9. Saved plan + environment gate
- **Context:** "Plan in CI, then apply" can apply something different from what was reviewed if `main` or AWS changed in between.
- **Decision:** The apply workflow plans with the read-only role, uploads `tfplan` as an artifact, waits for approval on the `prod` environment, then runs `terraform apply tfplan`.
- **Consequence:** What you approve is exactly what runs. If state moved in the meantime, Terraform refuses (`Saved plan is stale`); re-run the workflow. Plan artifacts are readable by other signed-in users on a public repo, which is one more reason nothing secret may be in state.

## 10. Per-stack concurrency
- **Decision:** Apply jobs use group `tf-state-<stack>` with `cancel-in-progress: false` (queued, never killed mid-apply). PR plans use a per-PR group (a new push cancels the old plan). All plans (PR, apply-plan, drift) use `-lock=false`; only `terraform apply` locks, with `-lock-timeout=10m`.

## 11. App instance ignores AMI changes
- **Decision:** `lifecycle { ignore_changes = [ami] }` on the EC2 instance.
- **Consequence:** New AL2023 releases don't show up as a nightly "replace" in drift. Roll AMIs on purpose; prod uses an ASG + launch template for this.

## 12. Deletion protection everywhere
- **Decision:** `prevent_destroy = true` on the state bucket, state KMS key (30-day window), NAT EIPs and RDS; RDS and ALB `deletion_protection = true`; RDS takes a final snapshot. No `force_destroy` on the state bucket.
- **Consequence:** Nothing stateful can be destroyed by accident, not even by a `terraform destroy`. To remove something on purpose, first change the code in a PR (flip the flag), apply that, then remove the resource.
