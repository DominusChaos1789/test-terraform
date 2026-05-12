###############################################################################
# eventbridge.tf
#
# EventBridge rules and targets that trigger each Glue job
# daily at 05:00 COT (10:00 UTC) — Colombia does not observe DST.
#
# cron expression: cron(0 10 * * ? *)
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# RULES  – one scheduled rule per schema
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "glue_schedule" {
  for_each = local.schema_map

  name                = "${var.project}-${var.environment}-${each.key}-schedule"
  description         = "Triggers Glue extractor for schema ${each.key} at 05:00 COT"
  schedule_expression = "cron(0 10 * * ? *)" # 10:00 UTC = 05:00 COT (UTC-5)
  state               = var.schedule_enabled ? "ENABLED" : "DISABLED"

  tags = merge(var.tags, { Schema = each.key })
}

# ─────────────────────────────────────────────────────────────────────────────
# TARGETS  – point each rule at its corresponding Glue job
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_event_target" "glue_job_target" {
  for_each = local.schema_map

  rule      = aws_cloudwatch_event_rule.glue_schedule[each.key].name
  target_id = "${var.project}-${var.environment}-${each.key}-glue-target"
  arn       = aws_glue_job.extractor[each.key].arn
  role_arn  = aws_iam_role.eventbridge_role.arn
}
