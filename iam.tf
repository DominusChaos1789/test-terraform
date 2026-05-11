###############################################################################
# iam.tf
#
# IAM Roles and policy attachments.
# Policy JSON documents live in data.tf.
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# GLUE IAM ROLE
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "glue_role" {
  name               = "${var.project}-${var.environment}-glue-extractor-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
  description        = "IAM role for Glue Aurora extractor jobs (${var.environment})"

  tags = var.tags
}

# Attach AWS managed Glue service role (covers basic Glue internals)
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Inline: S3 access (landing + scripts)
resource "aws_iam_role_policy" "glue_s3" {
  name   = "glue-s3-access"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_s3.json
}

# Inline: Secrets Manager – read DB credentials
resource "aws_iam_role_policy" "glue_secrets" {
  name   = "glue-secrets-manager"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_secrets_manager.json
}

# Inline: Glue Catalog operations
resource "aws_iam_role_policy" "glue_catalog" {
  name   = "glue-catalog-access"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_catalog.json
}

# Inline: CloudWatch Logs
resource "aws_iam_role_policy" "glue_cloudwatch" {
  name   = "glue-cloudwatch-logs"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_cloudwatch.json
}

# Inline: EC2/VPC (Glue ↔ Aurora VPC connectivity)
resource "aws_iam_role_policy" "glue_vpc" {
  name   = "glue-vpc-access"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_vpc.json
}

# Inline: KMS (optional – only needed if CMK encryption is used)
resource "aws_iam_role_policy" "glue_kms" {
  count  = var.enable_kms_policy ? 1 : 0
  name   = "glue-kms-access"
  role   = aws_iam_role.glue_role.id
  policy = data.aws_iam_policy_document.glue_kms.json
}

# ─────────────────────────────────────────────────────────────────────────────
# EVENTBRIDGE IAM ROLE
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "eventbridge_role" {
  name               = "${var.project}-${var.environment}-eventbridge-glue-role"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume_role.json
  description        = "IAM role that allows EventBridge to trigger Glue extractor jobs"

  tags = var.tags
}

# Inline: allow EventBridge to start Glue jobs
resource "aws_iam_role_policy" "eventbridge_glue" {
  name   = "eventbridge-start-glue-jobs"
  role   = aws_iam_role.eventbridge_role.id
  policy = data.aws_iam_policy_document.eventbridge_start_glue_jobs.json
}
