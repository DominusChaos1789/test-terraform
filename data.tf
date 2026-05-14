# ============================================================
#  data.tf
#  All data sources: current account/region, S3 bucket refs,
#  and every IAM policy document used in iam.tf.
#  ARNs are always derived here — never hard-coded.
# ============================================================

# ─── Account & region context ───────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ─── S3 bucket lookups ──────────────────────────────────────────────────────
data "aws_s3_bucket" "landing" {
  bucket = var.landing_bucket_name
}

data "aws_s3_bucket" "logs" {
  bucket = var.logs_bucket_name
}

data "aws_s3_bucket" "resources" {
  bucket = var.resources_bucket_name
}

# ─── VPC / Networking (for Glue connection) ─────────────────────────────────
data "aws_vpc" "aurora_vpc" {
  id = var.aurora_vpc_id
}

data "aws_subnet" "glue_primary" {
  id = var.aurora_subnet_ids[0]
}

# ============================================================
#  IAM POLICY DOCUMENTS
# ============================================================

# ── 1. Glue: trust policy (who can assume the role) ─────────────────────────
data "aws_iam_policy_document" "glue_trust" {
  statement {
    sid     = "GlueAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

# ── 2. Glue: S3 access (landing write + resources read + logs write) ─────────
data "aws_iam_policy_document" "glue_s3" {
  # Read Glue script from dev-resources/cariai/
  statement {
    sid    = "ReadGlueScript"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      data.aws_s3_bucket.resources.arn,
      "${data.aws_s3_bucket.resources.arn}/${var.cariai_prefix}/*",
    ]
  }

  # Write extracted JSON to dev-landing/cariai/
  statement {
    sid    = "WriteLandingData"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetObject",
    ]
    resources = [
      data.aws_s3_bucket.landing.arn,
      "${data.aws_s3_bucket.landing.arn}/${var.cariai_prefix}/*",
    ]
  }

  # Write logs to dev-logs/cariai/
  statement {
    sid    = "WriteJobLogs"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      data.aws_s3_bucket.logs.arn,
      "${data.aws_s3_bucket.logs.arn}/${var.cariai_prefix}/*",
    ]
  }
}

# ── 3. Glue: CloudWatch Logs (job metrics & logs) ───────────────────────────
data "aws_iam_policy_document" "glue_cloudwatch" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:AssociateKmsKey",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*",
    ]
  }

  statement {
    sid    = "CloudWatchMetrics"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Glue"]
    }
  }
}

# ── 4. Glue: EC2/VPC networking (required for Glue connections) ──────────────
data "aws_iam_policy_document" "glue_vpc_networking" {
  statement {
    sid    = "GlueVpcNetworking"
    effect = "Allow"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeNetworkInterfaces",
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeRouteTables",
    ]
    resources = ["*"]
  }
}

# ── 5. Glue: Glue service permissions (catalog, connections, jobs) ───────────
data "aws_iam_policy_document" "glue_service" {
  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetConnection",
      "glue:GetConnections",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetJob",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchGetJobs",
    ]
    resources = ["*"]
  }
}

# ── 6. EventBridge: trust policy ─────────────────────────────────────────────
data "aws_iam_policy_document" "eventbridge_trust" {
  statement {
    sid     = "EventBridgeAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

# ── 7. EventBridge: permission to start the Glue job ─────────────────────────
data "aws_iam_policy_document" "eventbridge_start_glue" {
  statement {
    sid    = "StartGlueJob"
    effect = "Allow"
    actions = [
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchStopJobRun",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${local.job_name}",
    ]
  }
}
