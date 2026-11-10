# The VPC module can create this role itself, but it puts the IAM policy at path "/",
# which the CI apply role is (deliberately) not allowed to do. So we create it here,
# under /app/ with the workload boundary, and hand the ARN to the module.

locals {
  flow_log_group_arn = "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/vpc-flow-log/${var.name}"
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    # Confused-deputy protection: only flow logs in this account can use the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ec2:${var.region}:${var.account_id}:vpc-flow-log/*"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name                 = "${var.name}-vpc-flow-logs"
  path                 = "/app/"
  assume_role_policy   = data.aws_iam_policy_document.flow_logs_assume.json
  permissions_boundary = var.workload_permissions_boundary_arn
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    sid       = "WriteFlowLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [local.flow_log_group_arn, "${local.flow_log_group_arn}:*"]
  }

  statement {
    sid       = "DescribeLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}
