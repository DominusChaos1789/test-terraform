# ── Glue JDBC Connection ──────────────────────────────────────────────────────
# One shared connection for all 36 Aurora MySQL databases.
# The Python script appends the specific database name to the base JDBC URL.
resource "aws_glue_connection" "aurora_mysql" {
  name            = local.connection_name
  description     = "JDBC connection to Aurora MySQL cluster (host read from Parameter Store)"
  connection_type = local.connection_params["type"] # "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = local.jdbc_url
    # Credentials are injected at runtime from Parameter Store via the job script.
    # Glue requires these keys to exist; we set placeholder values and let the
    # script override via boto3/SSM at execution time.
    USERNAME = "placeholder"
    PASSWORD  = "placeholder"
  }

  physical_connection_requirements {
    subnet_id              = local.subnet_id
    security_group_id_list = local.security_group_ids
    availability_zone      = "${var.aws_region}a" # overrideable via locals if needed
  }

  tags = local.common_tags
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "glue_job" {
  name              = "/aws-glue/jobs/${local.job_name}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

# ── Glue Job ──────────────────────────────────────────────────────────────────
resource "aws_glue_job" "extractor" {
  name        = local.job_name
  description = local.job_description
  role_arn    = aws_iam_role.glue_job.arn

  glue_version      = local.glue_version
  worker_type       = local.worker_type
  number_of_workers = local.number_of_workers
  max_retries       = local.max_retries
  timeout           = local.timeout_minutes

  connections = [aws_glue_connection.aurora_mysql.name]

  command {
    name            = "glueetl"
    python_version  = local.python_version
    script_location = "s3://${local.landing_bucket_name}/${local.script_s3_key}"
  }

  default_arguments = merge(
    {
      # Glue built-ins
      "--job-language"                     = "python"
      "--job-bookmark-option"              = var.enable_bookmark ? "job-bookmark-enable" : "job-bookmark-disable"
      "--enable-continuous-cloudwatch-log" = "true"
      "--enable-metrics"                   = "true"
      "--enable-spark-ui"                  = "false"
      "--TempDir"                          = "s3://${local.landing_bucket_name}/tmp/${local.job_name}/"
      "--extra-jars"                       = length(var.glue_extra_jars) > 0 ? join(",", var.glue_extra_jars) : ""

      # Custom arguments read by the Python script
      "--ssm_parameter_path" = local.ssm_parameter_path
      "--s3_landing_bucket"  = local.landing_bucket_name
      "--db_list"            = local.db_list
      "--aws_region"         = var.aws_region
    },
    var.additional_job_args
  )

  execution_property {
    max_concurrent_runs = 1
  }

  tags = local.common_tags

  depends_on = [aws_cloudwatch_log_group.glue_job]
}

# ── EventBridge Scheduler (5 AM COT = 10 AM UTC) ──────────────────────────────
resource "aws_scheduler_schedule" "glue_job_trigger" {
  name        = "${local.job_name}-daily-trigger"
  description = "Triggers ${local.job_name} every day at 05:00 COT (10:00 UTC)"
  group_name  = "default"

  flexible_time_window {
    mode = "OFF" # exact time, no flexibility window
  }

  schedule_expression          = local.schedule_expression
  schedule_expression_timezone = "America/Bogota" # COT — EventBridge supports IANA tz

  target {
    arn      = "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${local.job_name}"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      JobName = local.job_name
    })
  }

  depends_on = [aws_glue_job.extractor]
}
