###############################################################################
# data.tf
#
# All IAM policy documents (JSON) and AWS data sources.
# No resource blocks — purely data sources and iam_policy_documents.
#
# Sections:
#   1. AWS data sources
#   2. Trust policies        (assume-role)
#   3. Glue module policies  (merged into one combined document)
#   4. EventBridge policies  (scoped to resource ARNs, not strings)
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# 1. AWS DATA SOURCES
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# S3 bucket objects – resolve ARNs from resource references, not string templates
data "aws_s3_bucket" "landing" {
  bucket = var.landing_bucket
}

data "aws_s3_bucket" "scripts" {
  bucket = var.scripts_bucket
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. TRUST POLICIES
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "glue_assume_role" {
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

data "aws_iam_policy_document" "eventbridge_assume_role" {
  statement {
    sid     = "EventBridgeAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. GLUE MODULE POLICIES
#    Each statement group is defined separately for readability,
#    then merged into glue_combined via source_policy_documents.
#    iam.tf attaches only glue_combined (+ optional glue_kms).
# ─────────────────────────────────────────────────────────────────────────────

# S3 – scripts bucket (read) and landing bucket (write)
data "aws_iam_policy_document" "glue_s3" {
  statement {
    sid    = "ReadGlueScripts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      data.aws_s3_bucket.scripts.arn,
      "${data.aws_s3_bucket.scripts.arn}/*",
    ]
  }

  statement {
    sid    = "WriteLandingBucket"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      data.aws_s3_bucket.landing.arn,
      "${data.aws_s3_bucket.landing.arn}/*",
    ]
  }

  statement {
    sid    = "WriteGlueTempAndLogs"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${data.aws_s3_bucket.scripts.arn}/tmp/*",
      "${data.aws_s3_bucket.scripts.arn}/spark-logs/*",
    ]
  }
}

# Secrets Manager – scoped to the secrets created by secrets.tf
data "aws_iam_policy_document" "glue_secrets_manager" {
  statement {
    sid    = "ReadSchemaSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = values(aws_secretsmanager_secret.schema_credentials)[*].arn
  }
}

# Glue Catalog – create/update databases and tables
data "aws_iam_policy_document" "glue_catalog" {
  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:BatchCreatePartition",
      "glue:CreatePartition",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
      "glue:GetConnection",
      "glue:GetConnections",
    ]
    resources = ["*"]
  }
}

# CloudWatch Logs – Glue continuous logging
data "aws_iam_policy_document" "glue_cloudwatch" {
  statement {
    sid    = "GlueCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:AssociateKmsKey",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*",
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*:*",
    ]
  }
}

# EC2/VPC – Glue ENI management for Aurora connectivity
data "aws_iam_policy_document" "glue_vpc" {
  statement {
    sid    = "GlueVPCAccess"
    effect = "Allow"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeNetworkInterfaces",
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:AttachNetworkInterface",
      "ec2:DescribeVpcEndpoints",
      "ec2:DescribeRouteTables",
    ]
    resources = ["*"]
  }
}

# Merge all Glue policy documents into one → attached as a single inline policy
data "aws_iam_policy_document" "glue_combined" {
  source_policy_documents = [
    data.aws_iam_policy_document.glue_s3.json,
    data.aws_iam_policy_document.glue_secrets_manager.json,
    data.aws_iam_policy_document.glue_catalog.json,
    data.aws_iam_policy_document.glue_cloudwatch.json,
    data.aws_iam_policy_document.glue_vpc.json,
  ]
}

# KMS – kept separate because it is conditionally attached (enable_kms_policy)
data "aws_iam_policy_document" "glue_kms" {
  statement {
    sid    = "GlueKMSDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values = [
        "s3.${data.aws_region.current.name}.amazonaws.com",
        "secretsmanager.${data.aws_region.current.name}.amazonaws.com",
      ]
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. EVENTBRIDGE POLICIES
#    Resource list built from the actual Glue job ARNs (no string templates).
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "eventbridge_start_glue_jobs" {
  statement {
    sid     = "StartGlueExtractorJobs"
    effect  = "Allow"
    actions = ["glue:StartJobRun"]

    # Reference job ARNs directly — no hardcoded account ID or region strings
    resources = values(aws_glue_job.extractor)[*].arn
  }
}
