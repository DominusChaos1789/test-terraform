###############################################################################
# iam.tf
#
# IAM roles and policy attachments, grouped by the service module they serve.
# All policy JSON documents are defined in data.tf.
#
# Sections:
#   1. GLUE MODULE        – role + all Glue job policies merged into one inline
#   2. EVENTBRIDGE MODULE – role + policy to trigger Glue jobs
###############################################################################


# ═════════════════════════════════════════════════════════════════════════════
# 1. GLUE MODULE
# ═════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "glue_role" {
  name               = "${var.project}-${var.environment}-glue-extractor-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
  description        = "IAM role for Glue Aurora extractor jobs (${var.environment})"

  tags = var.tags
}

# AWS managed policy – covers core Glue service internals
resource "aws_iam_role_policy_attachment" "glue_service_managed" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Single inline policy merging all Glue permissions:
#   S3 (landing + scripts) | Secrets Manager | Glue Catalog | CloudWatch Logs | VPC
# Merged via source_policy_documents in data.tf to keep one attachment per role.
resource "aws_iam_role_policy" "glue_combined" {
  name   = "${var.project}-${var.environment}-glue-combined-policy"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_combined.json
}

# KMS inline policy – attached only when CMK encryption is enabled
resource "aws_iam_role_policy" "glue_kms" {
  count  = var.enable_kms_policy ? 1 : 0
  name   = "${var.project}-${var.environment}-glue-kms-policy"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_kms.json
}


# ═════════════════════════════════════════════════════════════════════════════
# 2. EVENTBRIDGE MODULE
# ═════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "eventbridge_role" {
  name               = "${var.project}-${var.environment}-eventbridge-glue-role"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume_role.json
  description        = "Allows EventBridge to trigger Glue extractor jobs (${var.environment})"

  tags = var.tags
}

# Single inline policy – scoped to StartJobRun on this project's extractor jobs only
resource "aws_iam_role_policy" "eventbridge_glue" {
  name   = "${var.project}-${var.environment}-eventbridge-glue-policy"
  role   = aws_iam_role.eventbridge_role.id
  policy = data.aws_iam_policy_document.eventbridge_start_glue_jobs.json
}
