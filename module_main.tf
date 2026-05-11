###############################################################################
# MODULE: glue_aurora_extractor
#
# Creates one AWS Glue Job per Aurora MySQL schema (up to 36 schemas).
# Each job reads from its own schema (credentials from Secrets Manager),
# writes Parquet to s3://dev-landing/<schema_name>/,
# and is triggered daily at 05:00 COT (= 10:00 UTC) via EventBridge.
###############################################################################

locals {
  # Build a flat map of schema_name -> config for easy iteration
  schema_map = { for s in var.schemas : s.name => s }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECRETS MANAGER  – one secret per schema (username + password)
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "schema_credentials" {
  for_each = local.schema_map

  name                    = "${var.environment}/${var.project}/${each.key}/db-credentials"
  description             = "Aurora MySQL credentials for schema ${each.key}"
  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(var.tags, { Schema = each.key })
}

resource "aws_secretsmanager_secret_version" "schema_credentials" {
  for_each = local.schema_map

  secret_id = aws_secretsmanager_secret.schema_credentials[each.key].id
  secret_string = jsonencode({
    username = each.value.db_user
    password = each.value.db_password
    host     = each.value.db_host
    port     = each.value.db_port
    dbname   = each.value.db_name
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# GLUE CONNECTION  – one JDBC connection per schema
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_glue_connection" "aurora" {
  for_each = local.schema_map

  name            = "${var.project}-${var.environment}-${each.key}-conn"
  connection_type = "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:mysql://${each.value.db_host}:${each.value.db_port}/${each.value.db_name}"
    USERNAME            = each.value.db_user
    PASSWORD            = each.value.db_password
  }

  physical_connection_requirements {
    availability_zone      = var.availability_zone
    security_group_id_list = var.glue_security_group_ids
    subnet_id              = var.glue_subnet_id
  }

  tags = merge(var.tags, { Schema = each.key })
}

# ─────────────────────────────────────────────────────────────────────────────
# GLUE JOBS  – one job per schema
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_glue_job" "extractor" {
  for_each = local.schema_map

  name              = "${var.project}-${var.environment}-${each.key}-extractor"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = var.glue_version
  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = var.job_timeout_minutes
  max_retries       = var.max_retries

  connections = [aws_glue_connection.aurora[each.key].name]

  command {
    name            = "glueetl"
    script_location = "s3://${var.scripts_bucket}/${var.scripts_prefix}/${each.key}_extractor.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = var.enable_job_bookmark ? "job-bookmark-enable" : "job-bookmark-disable"
    "--enable-metrics"                   = ""
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${var.scripts_bucket}/spark-logs/"
    "--TempDir"                          = "s3://${var.scripts_bucket}/tmp/"

    # Runtime parameters passed to each PySpark script
    "--SOURCE_SCHEMA"    = each.key
    "--SOURCE_HOST"      = each.value.db_host
    "--SOURCE_PORT"      = tostring(each.value.db_port)
    "--SOURCE_DB"        = each.value.db_name
    "--SECRET_ARN"       = aws_secretsmanager_secret.schema_credentials[each.key].arn
    "--TARGET_BUCKET"    = var.landing_bucket
    "--TARGET_PREFIX"    = each.key
    "--TARGET_FORMAT"    = var.output_format
    "--TABLES_TO_EXTRACT"= join(",", lookup(each.value, "tables", []))
  }

  tags = merge(var.tags, { Schema = each.key })
}

# ─────────────────────────────────────────────────────────────────────────────
# EVENTBRIDGE RULES  – 05:00 COT = 10:00 UTC  (cron: 0 10 * * ? *)
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "glue_schedule" {
  for_each = local.schema_map

  name                = "${var.project}-${var.environment}-${each.key}-schedule"
  description         = "Triggers Glue extractor for schema ${each.key} at 05:00 COT"
  schedule_expression = "cron(0 10 * * ? *)" # 10:00 UTC = 05:00 COT (UTC-5)
  state               = var.schedule_enabled ? "ENABLED" : "DISABLED"

  tags = merge(var.tags, { Schema = each.key })
}

resource "aws_cloudwatch_event_target" "glue_job_target" {
  for_each = local.schema_map

  rule      = aws_cloudwatch_event_rule.glue_schedule[each.key].name
  target_id = "${var.project}-${var.environment}-${each.key}-glue-target"
  arn       = "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:job/${aws_glue_job.extractor[each.key].name}"
  role_arn  = aws_iam_role.eventbridge_role.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# GLUE CATALOG DATABASE  – one logical DB per schema (optional but recommended)
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_glue_catalog_database" "schema_db" {
  for_each = local.schema_map

  name        = "${var.project}_${var.environment}_${replace(each.key, "-", "_")}"
  description = "Glue catalog for extracted data from schema ${each.key}"
}
