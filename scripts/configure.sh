#!/usr/bin/env bash
# Run from the repo root AFTER `terraform -chdir=bootstrap apply`.
# Fills the backend blocks and tfvars of network/app from bootstrap outputs,
# rewrites CODEOWNERS, and prints the GitHub repository variables. Safe to re-run.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "jq is required: sudo apt-get install -y jq" >&2; exit 1; }
[ -d bootstrap ] || { echo "run from the repo root" >&2; exit 1; }

out="$(terraform -chdir=bootstrap output -json)"
get() { jq -er "$1" <<<"$out"; }

bucket="$(get '.state_bucket_name.value')"
kms_key_arn="$(get '.state_kms_key_arn.value')"
boundary_arn="$(get '.workload_permissions_boundary_arn.value')"
account_id="$(get '.github_repository_variables.value.AWS_ACCOUNT_ID')"
region="$(get '.github_repository_variables.value.AWS_REGION')"
plan_role="$(get '.github_repository_variables.value.AWS_PLAN_ROLE_ARN')"
apply_role="$(get '.github_repository_variables.value.AWS_APPLY_ROLE_ARN')"

# Set `name = "value"` on the first line that assigns `name` (keeps indentation). Idempotent.
set_attr() {
  local file="$1" name="$2" value="$3"
  grep -qE "^[[:space:]]*${name}[[:space:]]*=" "$file" || { echo "no '${name}' in ${file}" >&2; exit 1; }
  sed -i -E "0,/^([[:space:]]*${name}[[:space:]]*=[[:space:]]*).*/s||\1\"${value}\"|" "$file"
}

for stack in network app; do
  dir="infra/prod/${stack}"
  set_attr "${dir}/versions.tf" bucket "$bucket"
  set_attr "${dir}/versions.tf" kms_key_id "$kms_key_arn"
  set_attr "${dir}/versions.tf" region "$region"
  set_attr "${dir}/terraform.tfvars" account_id "$account_id"
  set_attr "${dir}/terraform.tfvars" region "$region"
  set_attr "${dir}/terraform.tfvars" workload_permissions_boundary_arn "$boundary_arn"
  echo "configured ${dir}"
done

# CODEOWNERS from github_org in bootstrap/terraform.tfvars
gh_user="$(sed -nE 's/^[[:space:]]*github_org[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' bootstrap/terraform.tfvars | head -1)"
if [ -n "$gh_user" ]; then
  cat > .github/CODEOWNERS <<CODEOWNERS
* @${gh_user}
/bootstrap/ @${gh_user}
/.github/ @${gh_user}
CODEOWNERS
  echo "configured .github/CODEOWNERS for ${gh_user}"
fi

cat <<MSG

GitHub repository variables (Settings -> Secrets and variables -> Actions -> Variables; none are secrets):
  AWS_ACCOUNT_ID     = ${account_id}
  AWS_REGION         = ${region}
  AWS_PLAN_ROLE_ARN  = ${plan_role}
  AWS_APPLY_ROLE_ARN = ${apply_role}

Or with the gh CLI, from the repo root:
  gh variable set AWS_ACCOUNT_ID     --body '${account_id}'
  gh variable set AWS_REGION         --body '${region}'
  gh variable set AWS_PLAN_ROLE_ARN  --body '${plan_role}'
  gh variable set AWS_APPLY_ROLE_ARN --body '${apply_role}'
MSG
