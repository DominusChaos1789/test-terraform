data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── SSM: shared JDBC connection config (host, port, type) ─────────────────────
data "aws_ssm_parameter" "connection" {
  name            = local.ssm_connection_path
  with_decryption = true
}

locals {
  connection_params = jsondecode(data.aws_ssm_parameter.connection.value)
  # Base URL — Python appends the database name:  jdbc:mysql://host:port/<db>
  jdbc_base_url = format(
    "jdbc:mysql://%s:%s/",
    local.connection_params["host"],
    tostring(local.connection_params["port"])
  )
}

# ── SSM: dataset/table catalog ────────────────────────────────────────────────
# Value example:
# {
#   "dim tables": [
#     { "id": "bots",    "name": "Bots",    "output": {"path": "bots"} },
#     { "id": "canales", "name": "Canales", "output": {"path": "canales"} }
#   ],
#   "fact tables": [
#     {
#       "id": "clientes",
#       "name": "ClientesV2_(yyyy_mm)",
#       "output": {"path": "clientes"},
#       "date_filter": {"column": "fecha_creacion", "format": "yyyy-MM-dd HH:mm:ss"}
#     },
#     ...
#   ]
# }
# The Python script reads this at runtime to know which tables to extract
# and how to apply date filters on fact tables.
data "aws_ssm_parameter" "datasets" {
  name            = local.ssm_datasets_path
  with_decryption = false   # not sensitive — no credentials here
}

# ── S3 landing bucket (pre-existing) ─────────────────────────────────────────
data "aws_s3_bucket" "landing" {
  bucket = local.landing_bucket_name
}

# ── IAM: Glue trust relationship ──────────────────────────────────────────────
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

# ── IAM: EventBridge Scheduler trust relationship ─────────────────────────────
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

# ── IAM: Glue job inline permissions ─────────────────────────────────────────
data "aws_iam_policy_document" "glue_job_permissions" {

  # S3 — write Parquet partitions + read script
  statement {
    sid    = "S3LandingReadWrite"
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

  # SSM — read both parameters (connection config + dataset catalog)
  statement {
    sid    = "SSMReadParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${local.ssm_connection_path}",
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${local.ssm_datasets_path}",
    ]
  }

  # Secrets Manager — per-database credentials (one secret per DB)
  # Secret format: {"user": "...", "password": "..."}
  statement {
    sid    = "SecretsManagerReadDbCredentials"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = local.db_secret_arns
  }

  # KMS — decrypt SSM SecureStrings and Secrets Manager secrets
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
      values = [
        "ssm.${data.aws_region.current.name}.amazonaws.com",
        "secretsmanager.${data.aws_region.current.name}.amazonaws.com",
      ]
    }
  }

  # Glue catalog access
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

  # EC2 networking — Glue VPC-connected ENI management
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

# ── IAM: EventBridge Scheduler — start Glue job only ─────────────────────────
data "aws_iam_policy_document" "scheduler_permissions" {
  statement {
    sid    = "StartGlueJob"
    effect = "Allow"
    actions = ["glue:StartJobRun"]
    resources = [
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${local.job_name}",
    ]
  }
}
