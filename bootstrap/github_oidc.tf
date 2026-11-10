locals {
  repo         = "${var.github_org}/${var.github_repo}"
  iam_prefix   = "arn:aws:iam::${var.account_id}"
  app_path     = trim(var.app_iam_path, "/")
  oidc_sub_key = "token.actions.githubusercontent.com:sub"
  oidc_aud_key = "token.actions.githubusercontent.com:aud"

  # Who may assume which role. These are the `sub` claims GitHub puts in the OIDC token.
  plan_subjects = [
    "repo:${local.repo}:pull_request",        # PR plans
    "repo:${local.repo}:ref:refs/heads/main", # plan step of the apply workflow + nightly drift check
  ]
  apply_subjects = [
    var.use_github_environment
    ? "repo:${local.repo}:environment:${var.github_environment}"
    : "repo:${local.repo}:ref:refs/heads/main",
  ]
}

# ---------------------------------------------------------------------------
# GitHub OIDC identity provider (no thumbprint needed: AWS validates GitHub's
# certificate against its own trusted CA library)
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_aud_key
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_sub_key
      values   = local.plan_subjects
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_aud_key
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_sub_key
      values   = local.apply_subjects
    }
  }
}

# ---------------------------------------------------------------------------
# Shared: read the state file. All plans run with -lock=false (a plan never
# writes state), so the plan role needs no write access to the bucket at all.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "state_read" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "DecryptState"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.state.arn]
  }
}

# ---------------------------------------------------------------------------
# PLAN role: read-only. Used by PR plans, so assume any code in a PR can run
# with these permissions. It can see resource configuration, but not data.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "plan" {
  name                 = "github-terraform-plan"
  path                 = "/ci/"
  description          = "Read-only Terraform plan role for ${local.repo}"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-read"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_read.json
}

data "aws_iam_policy_document" "plan_deny_data_reads" {
  statement {
    sid    = "DenySecretValues"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:BatchGetSecretValue",
    ]
    resources = ["*"]
  }

  # Your own parameters are denied; AWS public parameters (e.g. /aws/service/ami-*) still work.
  # If your Terraform reads your own SSM parameters in data sources, narrow this.
  statement {
    sid       = "DenyOwnParameterValues"
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    resources = ["arn:aws:ssm:*:${var.account_id}:parameter/*"]
  }

  # ReadOnlyAccess can read any S3 object; limit that to the state bucket.
  statement {
    sid           = "DenyObjectReadsOutsideState"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "DenyTableData"
    effect    = "Deny"
    actions   = ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:GetRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan_deny" {
  name   = "deny-data-reads"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_deny_data_reads.json
}

# ---------------------------------------------------------------------------
# Permissions boundary for every IAM role your app Terraform creates.
# Stops privilege escalation: roles the apply role creates can never touch IAM,
# the Terraform state, or the CI roles, whatever policy is attached to them.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "workload_boundary" {
  # A boundary is a ceiling, not a grant: effective permissions are the intersection
  # of this and the role's own policies, so the broad statements here are intentional.
  #checkov:skip=CKV_AWS_107:Permissions boundary, not a grant
  #checkov:skip=CKV_AWS_108:Permissions boundary, not a grant
  #checkov:skip=CKV_AWS_109:Permissions boundary, not a grant
  #checkov:skip=CKV_AWS_110:Permissions boundary, not a grant
  #checkov:skip=CKV_AWS_111:Permissions boundary, not a grant
  #checkov:skip=CKV_AWS_356:Permissions boundary, not a grant

  statement {
    sid         = "AllowEverythingExceptIdentityAndAccountAdmin"
    not_actions = ["iam:*", "organizations:*", "account:*", "sso:*", "identitystore:*"]
    resources   = ["*"]
  }

  # EC2 needs to pass its own instance role in a few edge cases; allow only app roles.
  statement {
    sid       = "AllowPassingAppRoles"
    actions   = ["iam:PassRole", "iam:GetRole"]
    resources = ["${local.iam_prefix}:role/${local.app_path}/*"]
  }

  statement {
    sid       = "DenyStateAccess"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "DenyStateKey"
    effect    = "Deny"
    actions   = ["kms:*"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "workload-permissions-boundary"
  path        = "/ci/"
  description = "Permissions boundary required on every IAM role created by app Terraform"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# ---------------------------------------------------------------------------
# APPLY role: can build your stack, but IAM is fenced in (see above) and it
# cannot modify itself, the plan role, the OIDC provider, or the state bucket.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "apply" {
  name                 = "github-terraform-apply"
  path                 = "/ci/"
  description          = "Terraform apply role for ${local.repo}"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 7200 # RDS Multi-AZ creates/modifies can take a while
}

# Everything except IAM / Organizations / Account management.
resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "apply_state" {
  name   = "terraform-state-read"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.state_read.json
}

# Write state and the .tflock file (S3 native locking).
data "aws_iam_policy_document" "apply_state_write" {
  statement {
    sid       = "WriteStateAndLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "EncryptState"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "apply_state_write" {
  name   = "terraform-state-write"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_state_write.json
}

data "aws_iam_policy_document" "apply_iam" {
  #checkov:skip=CKV_AWS_356:Only read-only iam:Get*/List* use "*"; all write actions are path-scoped

  statement {
    sid       = "IamRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # CHECK vs prod: lines 267-279 were not in the screenshots (sid name inferred).
  # Roles under the app path can only be created/changed if they carry the workload boundary.
  statement {
    sid = "CreateAppRolesWithBoundary"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = ["${local.iam_prefix}:role/${local.app_path}/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    sid = "ManageAppRoles"
    actions = [
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PassRole",
    ]
    resources = ["${local.iam_prefix}:role/${local.app_path}/*"]
  }

  statement {
    sid = "ManageAppInstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["${local.iam_prefix}:instance-profile/${local.app_path}/*"]
  }

  statement {
    sid = "ManageAppPolicies"
    actions = [
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = ["${local.iam_prefix}:policy/${local.app_path}/*"]
  }
}

# CHECK vs prod: lines 337-354 were not in the screenshots (policy name and first sid inferred).
resource "aws_iam_role_policy" "apply_iam" {
  name   = "app-iam"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_iam.json
}

data "aws_iam_policy_document" "apply_guardrails" {
  statement {
    sid         = "HandsOffCiPlumbing"
    effect      = "Deny"
    not_actions = ["iam:Get*", "iam:List*"]
    resources = [
      aws_iam_role.plan.arn,
      aws_iam_role.apply.arn, # itself
      aws_iam_policy.workload_boundary.arn,
      aws_iam_openid_connect_provider.github.arn,
    ]
  }

  statement {
    sid    = "HandsOffStateBucketConfig"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
    ]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid    = "HandsOffStateKey"
    effect = "Deny"
    actions = [
      "kms:ScheduleKeyDeletion",
      "kms:DisableKey",
      "kms:PutKeyPolicy",
      "kms:DisableKeyRotation",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
    ]
    resources = [aws_kms_key.state.arn, "arn:aws:kms:*:${var.account_id}:alias/terraform-state"]
  }

  # Belt and braces in case you don't have Organizations SCPs yet.
  statement {
    sid    = "DontBlindTheAuditLogs"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "guardduty:DeleteDetector",
      "guardduty:DisassociateFromMasterAccount",
      "config:StopConfigurationRecorder",
      "config:DeleteConfigurationRecorder",
      "securityhub:DisableSecurityHub",
    ]
    resources = ["*"]
  }
}

# CHECK vs prod: lines 412-415 were not in the screenshots (role/policy lines inferred).
resource "aws_iam_role_policy" "apply_guardrails" {
  name   = "guardrails"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_guardrails.json
}
