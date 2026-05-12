###############################################################################
# glue.tf
#
# Glue JDBC connections, ETL jobs, and Catalog databases.
# One of each resource per schema (for_each over local.schema_map).
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# GLUE CONNECTIONS  – JDBC connection to each Aurora schema
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
# GLUE JOBS  – one ETL job per schema
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

    "--SOURCE_SCHEMA"     = each.key
    "--SOURCE_HOST"       = each.value.db_host
    "--SOURCE_PORT"       = tostring(each.value.db_port)
    "--SOURCE_DB"         = each.value.db_name
    "--SECRET_ARN"        = aws_secretsmanager_secret.schema_credentials[each.key].arn
    "--TARGET_BUCKET"     = var.landing_bucket
    "--TARGET_PREFIX"     = each.key
    "--TARGET_FORMAT"     = var.output_format
    "--TABLES_TO_EXTRACT" = join(",", lookup(each.value, "tables", []))
  }

  tags = merge(var.tags, { Schema = each.key })
}

# ─────────────────────────────────────────────────────────────────────────────
# GLUE CATALOG DATABASES  – one logical database per schema
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_glue_catalog_database" "schema_db" {
  for_each = local.schema_map

  name        = "${var.project}_${var.environment}_${replace(each.key, "-", "_")}"
  description = "Glue catalog for extracted data from schema ${each.key}"
}
