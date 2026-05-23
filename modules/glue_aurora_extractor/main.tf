# =============================================================================
# MODULE: glue_aurora_extractor
# Description : Provisions one AWS Glue Job that extracts data from N Aurora
#               MySQL databases and lands Parquet files in S3. Connections are
#               created automatically (one per database index). The job is
#               triggered by an EventBridge rule on a CRON schedule.
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Read connection parameters from Parameter Store
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "connection" {
  name            = var.ssm_connection_path
  with_decryption = true
}

locals {
  conn_params = jsondecode(data.aws_ssm_parameter.connection.value)

  # Iterate over every database index (0 → db_count-1)
  db_indexes = range(var.db_count)

  # EventBridge cron — 05:00 COT = 10:00 UTC
  schedule_expression = "cron(0 10 * * ? *)"
}

# ---------------------------------------------------------------------------
# 2. Glue connections  (one per Aurora MySQL instance)
# ---------------------------------------------------------------------------
resource "aws_glue_connection" "aurora_db" {
  for_each = toset([for i in local.db_indexes : tostring(i)])

  name            = "${var.job_name}-conn-db${each.key}"
  connection_type = local.conn_params["type"] # "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:mysql://${local.conn_params["host"]}:${local.conn_params["port"]}/${var.database_names[tonumber(each.key)]}"
    USERNAME            = var.db_username
    PASSWORD            = var.db_password
  }

  physical_connection_requirements {
    availability_zone      = var.availability_zone
    security_group_id_list = [var.security_group_id]
    subnet_id              = var.subnet_id
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 3. IAM Role for the Glue job
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_job" {
  name               = "${var.job_name}-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
  tags               = var.tags
}

# Attach AWS-managed Glue service policy
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Inline policy: S3 write + SSM read
data "aws_iam_policy_document" "glue_inline" {
  # S3 — write to the landing bucket
  statement {
    sid    = "S3LandingWrite"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.landing_bucket}",
      "arn:aws:s3:::${var.landing_bucket}/*",
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
      "arn:aws:ssm:*:*:parameter/${trimprefix(var.ssm_connection_path, "/")}",
    ]
  }

  # Glue connections — describe & use
  statement {
    sid    = "GlueConnections"
    effect = "Allow"
    actions = [
      "glue:GetConnection",
      "glue:GetConnections",
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
    resources = ["arn:aws:logs:*:*:/aws-glue/*"]
  }
}

resource "aws_iam_role_policy" "glue_inline" {
  name   = "${var.job_name}-inline-policy"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_inline.json
}

# ---------------------------------------------------------------------------
# 4. Upload the PySpark script to S3
# ---------------------------------------------------------------------------
resource "aws_s3_object" "glue_script" {
  bucket = var.scripts_bucket
  key    = "glue-scripts/${var.job_name}/extractor.py"
  source = "${path.module}/scripts/extractor.py"
  etag   = filemd5("${path.module}/scripts/extractor.py")
  tags   = var.tags
}

# ---------------------------------------------------------------------------
# 5. Glue Job definition
# ---------------------------------------------------------------------------
resource "aws_glue_job" "extractor" {
  name     = var.job_name
  role_arn = aws_iam_role.glue_job.arn

  glue_version      = "4.0"
  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = var.job_timeout_minutes

  connections = [for i in local.db_indexes : aws_glue_connection.aurora_db[tostring(i)].name]

  command {
    name            = "glueetl"
    script_location = "s3://${var.scripts_bucket}/glue-scripts/${var.job_name}/extractor.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-disable"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "false"
    "--TempDir"                          = "s3://${var.scripts_bucket}/glue-tmp/${var.job_name}/"
    "--DB_COUNT"                         = tostring(var.db_count)
    "--DATABASE_NAMES"                   = join(",", var.database_names)
    "--LANDING_BUCKET"                   = var.landing_bucket
    "--SSM_CONNECTION_PATH"              = var.ssm_connection_path
    "--CONNECTION_NAME_PREFIX"           = "${var.job_name}-conn-db"
    "--OUTPUT_FORMAT"                    = var.output_format
    "--TABLES_TO_EXTRACT"                = join(",", var.tables_to_extract)
  }

  execution_property {
    max_concurrent_runs = var.max_concurrent_runs
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 6. EventBridge rule — 05:00 COT (10:00 UTC) every day
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "glue_schedule" {
  name                = "${var.job_name}-schedule"
  description         = "Trigger ${var.job_name} daily at 05:00 COT (10:00 UTC)"
  schedule_expression = local.schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "glue_target" {
  rule      = aws_cloudwatch_event_rule.glue_schedule.name
  target_id = "${var.job_name}-target"
  arn       = "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${aws_glue_job.extractor.name}"
  role_arn  = aws_iam_role.eventbridge_glue.arn
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# IAM role so EventBridge can start the Glue job
resource "aws_iam_role" "eventbridge_glue" {
  name = "${var.job_name}-eventbridge-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }, {
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "eventbridge_glue_inline" {
  name = "${var.job_name}-eventbridge-policy"
  role = aws_iam_role.eventbridge_glue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["glue:StartJobRun"]
      Resource = aws_glue_job.extractor.arn
    }]
  })
}
