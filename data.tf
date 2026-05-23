data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# ── Parameter Store ────────────────────────────────────────────────────────────
# Reads the JSON blob: {"type":"JDBC","host":"10.32.127.4","port":"3306"}
data "aws_ssm_parameter" "connection" {
  name            = local.ssm_parameter_path
  with_decryption = true
}

locals {
  connection_params = jsondecode(data.aws_ssm_parameter.connection.value)
  jdbc_url = format(
    "jdbc:mysql://%s:%s/",
    local.connection_params["host"],
    tostring(local.connection_params["port"])
  )
}

# ── S3 landing bucket (already exists, just reference it) ──────────────────────
data "aws_s3_bucket" "landing" {
  bucket = local.landing_bucket_name
}

# ── IAM policy document: Glue trust relationship ──────────────────────────────
data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    sid     = "GlueAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

# ── IAM policy document: EventBridge trust relationship ───────────────────────
data "aws_iam_policy_document" "events_assume_role" {
  statement {
    sid     = "EventsAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

# ── IAM policy: inline permissions for the Glue job role ─────────────────────
data "aws_iam_policy_document" "glue_job_permissions" {
  # S3 — landing bucket write + scripts read
  statement {
    sid    = "S3LandingWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      data.aws_s3_bucket.landing.arn,
      "${data.aws_s3_bucket.landing.arn}/*",
    ]
  }

  # SSM — read the connection parameter
  statement {
    sid    = "SSMReadConnection"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${local.ssm_parameter_path}",
    ]
  }

  # KMS — decrypt SSM SecureString if applicable
  statement {
    sid    = "KMSDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }

  # Glue — allow the job to read its own catalog / connections
  statement {
    sid    = "GlueSelfAccess"
    effect = "Allow"
    actions = [
      "glue:GetConnection",
      "glue:GetConnections",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartitions",
    ]
    resources = ["*"]
  }

  # CloudWatch Logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*",
    ]
  }

  # EC2 networking — required by Glue to manage VPC-connected ENIs
  statement {
    sid    = "EC2NetworkingForGlue"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeRouteTables",
    ]
    resources = ["*"]
  }
}

# ── IAM policy: EventBridge Scheduler → start Glue job ───────────────────────
data "aws_iam_policy_document" "scheduler_permissions" {
  statement {
    sid    = "StartGlueJob"
    effect = "Allow"
    actions = [
      "glue:StartJobRun",
    ]
    resources = [
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${local.job_name}",
    ]
  }
}
