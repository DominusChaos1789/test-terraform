###############################################################################
# data.tf
#
# All IAM policy documents (JSON) and AWS data sources live here.
# No resource blocks — purely data sources and policy documents.
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# CALLER IDENTITY  – used to construct ARNs dynamically
# ─────────────────────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# TRUST POLICIES
# ─────────────────────────────────────────────────────────────────────────────

# Trust policy: AWS Glue service can assume the Glue IAM role
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

# Trust policy: EventBridge can assume the EventBridge IAM role
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
# GLUE ROLE – INLINE POLICIES
# ─────────────────────────────────────────────────────────────────────────────

# Policy: S3 access for dev-landing (write) and scripts bucket (read/write)
data "aws_iam_policy_document" "glue_s3" {
  # Read Glue scripts from the scripts bucket
  statement {
    sid    = "ReadGlueScripts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.scripts_bucket}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.scripts_bucket}/*",
    ]
  }

  # Write extracted data to dev-landing bucket
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
      "arn:${data.aws_partition.current.partition}:s3:::${var.landing_bucket}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.landing_bucket}/*",
    ]
  }

  # Write temp files and Spark event logs to scripts bucket
  statement {
    sid    = "WriteGlueTempAndLogs"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.scripts_bucket}/tmp/*",
      "arn:${data.aws_partition.current.partition}:s3:::${var.scripts_bucket}/spark-logs/*",
    ]
  }
}

# Policy: Secrets Manager – Glue reads DB credentials for all 36 schemas
data "aws_iam_policy_document" "glue_secrets_manager" {
  statement {
    sid    = "ReadSchemaSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.environment}/${var.project}/*",
    ]
  }
}

# Policy: Glue Catalog – create/update databases and tables
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

# Policy: CloudWatch Logs – Glue continuous logging
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
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*",
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws-glue/*:*",
    ]
  }
}

# Policy: EC2/VPC – Glue needs these to attach to VPC for Aurora connectivity
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

# Policy: KMS – decrypt secrets and S3 objects if encrypted with CMK
data "aws_iam_policy_document" "glue_kms" {
  statement {
    sid    = "GlueKMSDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*",
    ]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values = [
        "s3.${var.aws_region}.amazonaws.com",
        "secretsmanager.${var.aws_region}.amazonaws.com",
      ]
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# EVENTBRIDGE ROLE – INLINE POLICIES
# ─────────────────────────────────────────────────────────────────────────────

# Policy: EventBridge can start all Glue jobs in this project
data "aws_iam_policy_document" "eventbridge_start_glue_jobs" {
  statement {
    sid    = "StartGlueExtractorJobs"
    effect = "Allow"
    actions = [
      "glue:StartJobRun",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:job/${var.project}-${var.environment}-*-extractor",
    ]
  }
}
