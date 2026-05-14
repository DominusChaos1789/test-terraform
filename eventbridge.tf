# ============================================================
#  eventbridge.tf
#  EventBridge Scheduler rule that triggers the Glue job
#  every day at 05:00 COT (Colombia = UTC-5, no DST).
# ============================================================

resource "aws_scheduler_schedule" "cariai_daily" {
  name        = "${local.name_prefix}-daily-schedule"
  description = "Triggers CarIAI WhatsApp Glue extraction every day at 05:00 COT (10:00 UTC)"
  group_name  = "default"

  # Colombia observes COT (UTC-5) year-round — no daylight saving time.
  # cron(0 10 * * ? *) = 10:00 UTC = 05:00 COT
  schedule_expression          = var.schedule_cron
  schedule_expression_timezone = "America/Bogota"
  state                        = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF" # fire at the exact scheduled time
  }

  target {
    # ARN built from data sources — no hard-coded account/region
    arn      = "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${aws_glue_job.cariai_extractor.name}"
    role_arn = aws_iam_role.eventbridge_scheduler.arn

    input = jsonencode({
      JobName = aws_glue_job.cariai_extractor.name
    })

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}
