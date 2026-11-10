locals {
  state_bucket_name = coalesce(var.state_bucket_name, "tfstate-${var.account_id}-${var.region}")

  admin_principal_arn_patterns = length(var.admin_principal_arn_patterns) > 0 ? var.admin_principal_arn_patterns : [
    "arn:aws:iam::${var.account_id}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_AdministratorAccess_*",
  ]
}

# ---------------------------------------------------------------------------
# KMS key for state encryption
# ---------------------------------------------------------------------------
resource "aws_kms_key" "state" {
  #checkov:skip=CKV2_AWS_64:Default key policy delegates access control to IAM, which is scoped below
  description             = "Encrypts Terraform state for ${var.github_org}/${var.github_repo}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/terraform-state"
  target_key_id = aws_kms_key.state.key_id
}

# ---------------------------------------------------------------------------
# State bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV2_AWS_62:No consumers for event notifications
  #checkov:skip=CKV_AWS_18:Use CloudTrail S3 data events for this bucket instead of server access logs
  #checkov:skip=CKV_AWS_144:Versioning + prevent_destroy is enough for a single-region setup
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    # Keep the 50 most recent old versions no matter what, expire older ones after 90 days.
    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 50
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Only the two CI roles and your admin SSO role can touch state objects,
  # even if some other principal in the account is granted s3:* by mistake.
  statement {
    sid       = "DenyStateAccessExceptTerraformPrincipals"
    effect    = "Deny"
    actions   = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values = concat(
        [aws_iam_role.plan.arn, aws_iam_role.apply.arn],
        local.admin_principal_arn_patterns,
      )
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
