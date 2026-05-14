# ============================================================
#  main.tf
#  Local values shared across all files in the module.
#  Infrastructure resources are split into dedicated files:
#    glue.tf        – Glue connection, script upload, job
#    eventbridge.tf – EventBridge Scheduler rule & target
#    iam.tf         – IAM roles and policy attachments
#    data.tf        – Data sources and IAM policy documents
# ============================================================

locals {
  name_prefix = "${var.environment}-cariai-whatsapp"
  job_name    = "${local.name_prefix}-glue-job"

  # ── S3 paths (derived from variables, never hard-coded) ──────────────────
  script_s3_key  = "${var.cariai_prefix}/scripts/cariai_whatsapp_extractor.py"
  script_s3_uri  = "s3://${data.aws_s3_bucket.resources.bucket}/${local.script_s3_key}"
  landing_prefix = "${var.cariai_prefix}/"
  logs_prefix    = "${var.cariai_prefix}/"

  # ── Schema config serialised to JSON for the Glue --schemas argument ─────
  # In production replace plaintext passwords with Secrets Manager references.
  schemas_json = jsonencode([
    for s in var.cariai_schemas : {
      schema_name = s.schema_name
      username    = s.username
      password    = s.password
    }
  ])
}
