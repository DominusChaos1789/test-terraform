# ============================================================
#  main.tf
#  Core infrastructure:
#    - Locals
#    - Glue network connection (Aurora MySQL)
#    - Glue job definition
#    - S3 object: Python script upload
#    - EventBridge Scheduler rule (5 AM COT daily)
# ============================================================

locals {
  name_prefix = "${var.environment}-cariai-whatsapp"
  job_name    = "${local.name_prefix}-glue-job"

  # S3 paths (derived from variables, never hard-coded)
  script_s3_key  = "${var.cariai_prefix}/scripts/cariai_whatsapp_extractor.py"
  script_s3_uri  = "s3://${data.aws_s3_bucket.resources.bucket}/${local.script_s3_key}"
  landing_prefix = "${var.cariai_prefix}/"
  logs_prefix    = "${var.cariai_prefix}/"

  # Serialise schema config as JSON so the Glue script can read it
  # via the --schemas job argument. Passwords should come from
  # Secrets Manager in production — this keeps them as job params
  # for simplicity and marks the variable as sensitive.
  schemas_json = jsonencode([
    for s in var.cariai_schemas : {
      schema_name = s.schema_name
      username    = s.username
      password    = s.password
    }
  ])
}

# ─── Glue network connection (shared Aurora endpoint) ───────────────────────
resource "aws_glue_connection" "aurora_mysql" {
  name            = "${local.name_prefix}-aurora-connection"
  connection_type = "JDBC"
  description     = "Shared JDBC connection to Aurora MySQL for all CarIAI schemas"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:mysql://${var.aurora_host}:${var.aurora_port}/"
    USERNAME            = var.cariai_schemas[0].username # Glue connection needs a default; overridden in script
    PASSWORD            = var.cariai_schemas[0].password
    JDBC_ENFORCE_SSL    = "false"
  }

  physical_connection_requirements {
    availability_zone      = data.aws_subnet.glue_primary.availability_zone
    security_group_id_list = var.aurora_security_group_ids
    subnet_id              = data.aws_subnet.glue_primary.id
  }

  tags = var.tags
}

# ─── Upload Python extraction script to S3 ──────────────────────────────────
resource "aws_s3_object" "glue_script" {
  bucket = data.aws_s3_bucket.resources.bucket
  key    = local.script_s3_key
  source = "${path.module}/glue_script.py"
  etag   = filemd5("${path.module}/glue_script.py")

  tags = var.tags
}

# ─── Glue Job ───────────────────────────────────────────────────────────────
resource "aws_glue_job" "cariai_extractor" {
  name              = local.job_name
  description       = "Extracts WhatsApp data from 36 CarIAI Aurora MySQL schemas and lands JSON files in S3"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = var.glue_version
  number_of_workers = var.number_of_workers
  worker_type       = var.worker_type
  timeout           = var.job_timeout_minutes
  max_retries       = var.max_retries

  command {
    name            = "glueetl"
    script_location = local.script_s3_uri
    python_version  = var.python_version
  }

  connections = [aws_glue_connection.aurora_mysql.name]

  default_arguments = {
    # ── Standard Glue arguments ──────────────────────────────────────────
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--enable-job-insights"              = "true"
    "--job-bookmark-option"              = "job-bookmark-disable"

    # ── Logging (dev-logs/cariai/) ────────────────────────────────────────
    "--continuous-log-logGroup"          = "/aws-glue/jobs/${local.job_name}"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${data.aws_s3_bucket.logs.bucket}/${local.logs_prefix}spark-ui/"

    # ── Script-level arguments ────────────────────────────────────────────
    "--aurora_host"         = var.aurora_host
    "--aurora_port"         = tostring(var.aurora_port)
    "--schemas"             = local.schemas_json          # JSON list of {schema_name, username, password}
    "--landing_bucket"      = data.aws_s3_bucket.landing.bucket
    "--landing_prefix"      = local.landing_prefix
    "--extra-py-files"      = ""                          # add whl packages here if needed
    "--TempDir"             = "s3://${data.aws_s3_bucket.resources.bucket}/${var.cariai_prefix}/tmp/"
  }

  tags = var.tags

  depends_on = [aws_s3_object.glue_script]
}

# ─── EventBridge Scheduler (5 AM COT = 10:00 UTC) ───────────────────────────
resource "aws_scheduler_schedule" "cariai_daily" {
  name        = "${local.name_prefix}-daily-schedule"
  description = "Triggers CarIAI WhatsApp Glue extraction every day at 05:00 COT (10:00 UTC)"
  group_name  = "default"

  # COT is UTC-5 all year (Colombia does not observe DST)
  schedule_expression          = var.schedule_cron          # default: cron(0 10 * * ? *)
  schedule_expression_timezone = "America/Bogota"
  state                        = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF" # exact time, no flexibility window
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${aws_glue_job.cariai_extractor.name}"
    role_arn = aws_iam_role.eventbridge_scheduler.arn

    # Pass the job name as a parameter so the scheduler calls StartJobRun
    input = jsonencode({
      JobName = aws_glue_job.cariai_extractor.name
    })

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}
