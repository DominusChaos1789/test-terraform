# ── Glue Job IAM Role ─────────────────────────────────────────────────────────
resource "aws_iam_role" "glue_job" {
  name               = "${local.job_name}-glue-role"
  description        = "Execution role for the ${local.job_name} Glue job"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
  tags               = local.common_tags
}

# AWS-managed baseline policy for Glue jobs
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Custom inline policy with least-privilege permissions
resource "aws_iam_role_policy" "glue_job_inline" {
  name   = "${local.job_name}-inline-policy"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_job_permissions.json
}

# ── EventBridge Scheduler IAM Role ────────────────────────────────────────────
resource "aws_iam_role" "scheduler" {
  name               = "${local.job_name}-scheduler-role"
  description        = "Allows EventBridge Scheduler to trigger ${local.job_name}"
  assume_role_policy = data.aws_iam_policy_document.events_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "scheduler_inline" {
  name   = "${local.job_name}-scheduler-policy"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler_permissions.json
}
