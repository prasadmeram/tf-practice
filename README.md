# tf-practice

## What this is
Terraform repo for **prod** AWS (`ap-south-1`), deployed **only** by GitHub Actions through OIDC (no AWS keys in GitHub). The bootstrap matches the prod bootstrap exactly.
PRs get a plan comment. Merging to `main` plans again, waits for a human to approve the `prod` environment, then applies exactly that saved plan. A nightly job opens an issue when AWS drifts from `main`.

Stateful things are protected: `prevent_destroy` on the state bucket, state key, NAT EIPs and RDS, plus deletion protection on RDS and the ALB. **Nothing gets deleted unless you change the code first** (see "Deleting things").

## Roles
| Role | Who can assume it | What it can do |
|---|---|---|
| `github-terraform-plan` (path `/ci/`) | PRs to `main`, and jobs on `main` | Read-only (`ReadOnlyAccess`). Reads state, **writes nothing** (plans run with `-lock=false`). Denied secret values, account SSM params, DynamoDB items, S3 objects outside the state bucket. |
| `github-terraform-apply` (path `/ci/`) | Only jobs in the `prod` GitHub environment (or any job on `main` if `use_github_environment = false`) | `PowerUserAccess` (everything except IAM). IAM only under `/app/`, and only with the workload boundary. Can't modify itself, the plan role, the OIDC provider, the boundary, the state bucket config, the state key, or the audit logs. |

## Workflows
| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-pr.yml` | PR to `main` | For each **changed** stack: fmt, tflint, checkov, init, validate, test (network), plan. One sticky PR comment per stack, with a ⚠️ caution box if anything is destroyed/replaced. `terraform checks` is the single required status. |
| `terraform-apply.yml` | Push to `main` touching `infra/**`, or manual | `network` then `app` (changed stacks only; manual run = all), via `_terraform-apply-stack.yml`. |
| `_terraform-apply-stack.yml` | Called by the above | `plan` job (plan role) → saved plan artifact + step summary → `apply` job in the `prod` environment (approval) → `terraform apply tfplan`. Skipped when there are no changes. |
| `terraform-drift.yml` | 02:30 UTC daily, or manual | `plan -detailed-exitcode` per stack. Drift → opens/updates issue `Drift detected: <stack>`. Clean → closes it. |

## Layout
```
bootstrap/            run ONCE from your laptop: state bucket, KMS key, OIDC provider, both roles, boundary
infra/prod/network/   VPC, subnets in 3 AZs, NAT, endpoints, flow logs (changes rarely)
infra/prod/app/       EC2, SGs, IAM example, optional ALB/RDS (changes often)
.github/              workflows, CODEOWNERS, dependabot
scripts/configure.sh  fills backend blocks + tfvars from bootstrap outputs
docs/decisions.md     why it's built this way
```
Each `infra/prod/*` dir is a separate stack with its own state. The app finds the network **by name and tag** (data sources), so an app change can never touch routing.

---

## Tools to install (WSL Ubuntu)
```bash
sudo apt-get update && sudo apt-get install -y jq unzip pipx

# AWS CLI v2
curl -sSLo /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install
aws configure            # IAM user terraform-user, region ap-south-1
aws sts get-caller-identity   # note Account and Arn

# Linters (optional locally; CI runs them anyway)
curl -sSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
pipx install checkov && pipx ensurepath
bash <(curl -sSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) && sudo mv actionlint /usr/local/bin/

# GitHub CLI (optional, for `gh variable set` / `gh pr create`)
# https://github.com/cli/cli/blob/trunk/docs/install_linux.md
```
**Terraform must be 1.16.x** (`required_version = "~> 1.16.0"`; CI uses 1.16.4). 1.17 is refused. To install 1.16.4:
```bash
curl -sSLo /tmp/tf.zip https://releases.hashicorp.com/terraform/1.16.4/terraform_1.16.4_linux_amd64.zip
unzip -o /tmp/tf.zip -d /tmp && sudo mv /tmp/terraform /usr/local/bin/terraform && terraform version
```

## One-time setup

### 1. Bootstrap (from your laptop, your IAM user)
```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # fill in account_id, region, github_org, github_repo (+ admin ARN, see below)
terraform init
terraform plan
terraform apply
```
`admin_principal_arn_patterns` **must match whoever runs bootstrap** (`aws sts get-caller-identity --query Arn`). Empty = the SSO `AdministratorAccess` role. If you run as IAM user `terraform-user`, set it to `["arn:aws:iam::<account>:user/terraform-user"]`. Otherwise the bucket policy locks you out of state. Recovery: as root, delete the bucket policy.

If the account already has a GitHub OIDC provider (only one is allowed per account), apply fails with `EntityAlreadyExists`. Import it first: `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com`.

Then move bootstrap's own state into the bucket it just created:
```bash
terraform output -json backend_config_snippets | jq -r .bootstrap   # ready-to-paste block
# edit versions.tf: uncomment the backend "s3" block, paste bucket + kms_key_id
terraform init -migrate-state                  # answer "yes"
rm -f terraform.tfstate terraform.tfstate.backup
```

### 2. Point the stacks at the backend + lock files
```bash
cd ..   # repo root
./scripts/configure.sh      # fills REPLACE_* in network/app versions.tf + tfvars, writes CODEOWNERS, prints GitHub variables

for stack in network app; do
  (cd infra/prod/$stack && terraform init -backend=false && \
   terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64)
done
```
Commit both `.terraform.lock.hcl` files. CI runs `init -lockfile=readonly` and fails without them.

Optional local checks before pushing:
```bash
terraform fmt -recursive
(cd infra/prod/network && terraform validate && terraform test && tflint --init && tflint)
(cd infra/prod/app && terraform validate && tflint --init && tflint)
checkov -d infra --framework terraform --quiet
actionlint
```

### 3. GitHub settings
1. Create the repo `tf-practice`. **It must be public** (or you need a paid plan): on a free personal account, environment protection rules (required reviewers) only work on public repos. If the repo must stay private on GitHub Free, set `use_github_environment = false` in bootstrap: then any job on `main` can use the apply role, with no approval step.
2. **Settings → Secrets and variables → Actions → Variables:** `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN` (printed by `configure.sh`; none are secrets).
3. **Settings → Environments → New environment `prod`:** Required reviewers = you. Deployment branches = Selected branches → `main` only. (Optionally untick "Prevent self-review" so you can approve your own runs. It's off by default.)
4. **Settings → Branches → Add rule for `main`** (after the first push): require a PR before merging (1 approval, or 0 if you're the only person on the repo), and require the status check **`terraform checks`**. Note that GitHub won't let you approve your own PR. Solo, set required approvals to 0, or allow admins to bypass.

---

## The network
| Tier | Subnets | Route to internet | What goes here |
|---|---|---|---|
| public | 10.20.0.0/24, 10.20.1.0/24, 10.20.2.0/24 | Internet gateway | ALB and NAT only |
| private | 10.20.16.0/20, 10.20.32.0/20, 10.20.48.0/20 | Via NAT | EC2 / ASG |
| database | 10.20.64.0/24, 10.20.65.0/24, 10.20.66.0/24 | None | RDS |
| free | 10.20.80.0 – 10.20.255.255 | | future use |

**NAT modes** (`nat_gateway_mode`):
- `single` (**default**): one NAT in AZ a, one private route table shared by all private subnets. With `preallocate_nat_eips = true` (default), 3 EIPs are kept so egress IPs never change.
- `per_az`: one NAT and one route table per AZ.

**Switching single → per_az:** with `preallocate_nat_eips = true`, this only **adds** NATs 2 and 3 and route tables 2 and 3. NAT 1, its IP and route table 1 stay. The PR comment should show `2 to add` for NATs/route tables, a few in-place association updates, and **no caution box**. `tests/nat.tftest.hcl` checks this. 

**Interface endpoints:** `interface_endpoints = ["ssm","ssmmessages","ec2messages"]` lets Session Manager work without NAT. Each one is billed per AZ per hour.

## Day to day
1. Branch, change code, open a PR → read the plan comment. A red **CAUTION** box means something will be destroyed or replaced.
2. Merge → **Actions → terraform-apply** → review the plan in the run summary → **Review deployments → Approve**.
3. If apply fails with `Saved plan is stale`, someone changed state after the plan. Re-run the workflow (**Re-run all jobs**, or run it manually).
4. Network changes the app depends on go in their own PR, merged and applied first.
5. New IAM role? `path = "/app/"` + `permissions_boundary = var.workload_permissions_boundary_arn`, always.

---

## Practice run tonight
Push in three steps so each stack gets its own PR. CI only plans the stacks a PR touches, and the app plan needs the VPC to exist already.

> **Cost:** NAT is always on (`single` NAT + 3 EIPs ≈ $0.07/hr ≈ $1.70/day). Destroy the network when you're done practising.

```bash
cd ~/tf-practice
git init -b main
git add . ':!infra'
git commit -m "Bootstrap, workflows, docs"
git remote add origin git@github.com:<you>/tf-practice.git
git push -u origin main          # no infra/ yet → no apply run
```
Now do GitHub settings step 3.4 (branch protection).

**PR 1: network**
```bash
git switch -c network
git add infra/prod/network
git commit -m "Network stack"
git push -u origin network       # open the PR on GitHub
```
Check the PR: `network` plan comment, `terraform checks` green. Merge → Actions → terraform-apply → approve `prod`.

**PR 2: app**
```bash
git switch main && git pull
git switch -c app
git add infra/prod/app
git commit -m "App stack"
git push -u origin app
```
Same flow. Things to try:
- Edit an app SG rule in a branch and watch the plan comment update in place.
- Make a change that forces a replace (e.g. change `name` of `aws_security_group.app`) and look at the CAUTION box. Don't merge it.

**Drift:** in the console, edit a tag on the app instance (e.g. `Stack` → `oops`). Then **Actions → terraform-drift → Run workflow**. An issue `Drift detected: app` should open. Change the tag back, run drift again, and the issue closes.

## Deleting things
Protection is on, so `terraform destroy` refuses for protected resources. To delete on purpose, **change the code first**:

1. In a PR, turn protection off for what you want to remove:
   - network EIPs: `prevent_destroy = false` in `infra/prod/network/main.tf`
   - RDS: `deletion_protection = false`, `prevent_destroy = false` (and `skip_final_snapshot = true` if you don't want a snapshot)
   - ALB: `enable_deletion_protection = false`
   Merge and apply it (deletion protection is an AWS setting, so it must be applied first).
2. Then remove the resource from code (or set `enable_alb`/`enable_rds = false`) in a second PR, and merge + approve.
3. Whole stacks, in order `app` → `network`: after step 1, run `terraform destroy` in the stack from your laptop.
4. Bootstrap last: set `prevent_destroy = false` on the bucket and key, add `force_destroy = true` to the bucket (or empty it by hand, including old versions), move its state back to local (comment out the backend, `terraform init -migrate-state`), then `terraform destroy`. The KMS key waits 30 days in "pending deletion".

## Cost
Verify these on the AWS pricing page for ap-south-1. They are rough and change over time.

| Item | Default | Approx. cost |
|---|---|---|
| KMS key (state) | on | ~$1/month + requests |
| S3 state bucket, flow-log group, S3 gateway endpoint | on | ~$0 |
| EC2 t3.micro + 8 GB gp3 | on (app) | free tier, else ~$0.011/hr |
| NAT gateway (`single`) | **on** | ~$0.056/hr + ~$0.056/GB processed |
| Elastic IPs (3 pre-allocated) | **on** | ~$0.005/hr each (attached or not) |
| Interface endpoint | off | ~$0.01/hr **per AZ** each (+ data) |
| ALB | off | ~$0.0225/hr + LCUs |
| RDS db.t4g.micro + 20 GB | off | ~$0.016/hr + storage (free tier eligible) |
