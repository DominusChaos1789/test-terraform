# ============================================================
#  glue.tf
#  All AWS Glue resources:
#    - JDBC network connection to Aurora MySQL
#    - S3 upload of the Python extraction script
#    - Glue ETL job definition with full argument set
#
#  Locals are in main.tf | IAM in iam.tf | Schedule in eventbridge.tf
# ============================================================

# ─── JDBC network connection (shared Aurora host, schema-level creds) ────────
# The connection establishes VPC routing from Glue to Aurora.
# Per-schema credentials are passed at runtime via the --schemas argument
# so a single connection covers all 36 schemas.
resource "aws_glue_connection" "aurora_mysql" {
  name            = "${local.name_prefix}-aurora-connection"
  connection_type = "JDBC"
  description     = "Shared JDBC connection to Aurora MySQL cluster for all 36 CarIAI WhatsApp schemas"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:mysql://${var.aurora_host}:${var.aurora_port}/"
    # Glue requires a credential pair on the connection resource itself.
    # The script overrides these per-schema at runtime via pymysql.
    USERNAME         = var.cariai_schemas[0].username
    PASSWORD         = var.cariai_schemas[0].password
    JDBC_ENFORCE_SSL = "false"
  }

  physical_connection_requirements {
    availability_zone      = data.aws_subnet.glue_primary.availability_zone
    security_group_id_list = var.aurora_security_group_ids
    subnet_id              = data.aws_subnet.glue_primary.id
  }

  tags = merge(var.tags, { Module = "glue" })
}

# ─── Upload Python extraction script to dev-resources/cariai/ ───────────────
# The etag ensures Terraform redeploys the object whenever the script changes.
resource "aws_s3_object" "glue_script" {
  bucket = data.aws_s3_bucket.resources.bucket
  key    = local.script_s3_key
  source = "${path.module}/glue_script.py"
  etag   = filemd5("${path.module}/glue_script.py")

  tags = merge(var.tags, { Module = "glue" })
}

# ─── Glue ETL Job ────────────────────────────────────────────────────────────
resource "aws_glue_job" "cariai_extractor" {
  name        = local.job_name
  description = "Extracts WhatsApp data from 36 CarIAI Aurora MySQL schemas and lands gzip NDJSON files in dev-landing/cariai/"

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

  # Attach the shared Aurora connection for VPC routing
  connections = [aws_glue_connection.aurora_mysql.name]

  default_arguments = {
    # ── Glue runtime flags ────────────────────────────────────────────────
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    "--enable-job-insights"              = "true"
    "--job-bookmark-option"              = "job-bookmark-disable"

    # ── Log destinations (dev-logs/cariai/) ───────────────────────────────
    "--continuous-log-logGroup" = "/aws-glue/jobs/${local.job_name}"
    "--enable-spark-ui"         = "true"
    "--spark-event-logs-path"   = "s3://${data.aws_s3_bucket.logs.bucket}/${local.logs_prefix}spark-ui/"

    # ── Temp working directory (dev-resources/cariai/tmp/) ────────────────
    "--TempDir" = "s3://${data.aws_s3_bucket.resources.bucket}/${var.cariai_prefix}/tmp/"

    # ── Custom script arguments (read by glue_script.py) ─────────────────
    "--aurora_host"    = var.aurora_host
    "--aurora_port"    = tostring(var.aurora_port)
    "--schemas"        = local.schemas_json # JSON list: [{schema_name, username, password}]
    "--landing_bucket" = data.aws_s3_bucket.landing.bucket
    "--landing_prefix" = local.landing_prefix

    # ── Extra Python dependencies (add .whl S3 URIs here if needed) ───────
    "--extra-py-files" = ""
  }

  tags = merge(var.tags, { Module = "glue" })

  # Ensure the script exists in S3 before the job is created
  depends_on = [aws_s3_object.glue_script]
}
