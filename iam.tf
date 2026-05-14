# ============================================================
#  iam.tf
#  IAM roles and policy attachments grouped by logical module.
#  Policy *documents* live in data.tf; only resources here.
#  ARNs are always derived — never hard-coded.
# ============================================================

# ============================================================
#  MODULE: GLUE
# ============================================================

resource "aws_iam_role" "glue" {
  name               = "${local.name_prefix}-glue-role"
  description        = "Execution role for the CarIAI WhatsApp Glue extraction job"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json

  tags = merge(var.tags, { Module = "glue" })
}

# AWS-managed Glue service policy (covers basic Glue operations)
resource "aws_iam_role_policy_attachment" "glue_managed_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Inline: S3 access (landing, logs, resources)
resource "aws_iam_role_policy" "glue_s3" {
  name   = "cariai-glue-s3-access"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_s3.json
}

# Inline: CloudWatch Logs & Metrics
resource "aws_iam_role_policy" "glue_cloudwatch" {
  name   = "cariai-glue-cloudwatch"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_cloudwatch.json
}

# Inline: VPC/EC2 networking (needed for Glue connection to Aurora)
resource "aws_iam_role_policy" "glue_vpc_networking" {
  name   = "cariai-glue-vpc-networking"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_vpc_networking.json
}

# Inline: Glue catalog + connection access
resource "aws_iam_role_policy" "glue_service" {
  name   = "cariai-glue-service-access"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_service.json
}

# ============================================================
#  MODULE: EVENTBRIDGE SCHEDULER
# ============================================================

resource "aws_iam_role" "eventbridge_scheduler" {
  name               = "${local.name_prefix}-scheduler-role"
  description        = "Allows EventBridge Scheduler to start the CarIAI Glue job"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_trust.json

  tags = merge(var.tags, { Module = "eventbridge" })
}

# Inline: permission to call glue:StartJobRun on our specific job
resource "aws_iam_role_policy" "eventbridge_start_glue" {
  name   = "cariai-scheduler-start-glue"
  role   = aws_iam_role.eventbridge_scheduler.id
  policy = data.aws_iam_policy_document.eventbridge_start_glue.json
}
