# ============================================================
#  outputs.tf
# ============================================================

output "glue_job_name" {
  description = "Name of the CarIAI Glue extraction job"
  value       = aws_glue_job.cariai_extractor.name
}

output "glue_job_arn" {
  description = "ARN of the Glue job (derived at runtime)"
  value       = "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${aws_glue_job.cariai_extractor.name}"
}

output "glue_role_arn" {
  description = "ARN of the Glue execution IAM role"
  value       = aws_iam_role.glue.arn
}

output "glue_connection_name" {
  description = "Name of the Aurora Glue JDBC connection"
  value       = aws_glue_connection.aurora_mysql.name
}

output "scheduler_role_arn" {
  description = "ARN of the EventBridge Scheduler IAM role"
  value       = aws_iam_role.eventbridge_scheduler.arn
}

output "schedule_name" {
  description = "EventBridge Scheduler schedule name"
  value       = aws_scheduler_schedule.cariai_daily.name
}

output "script_s3_uri" {
  description = "S3 URI of the uploaded Glue Python script"
  value       = local.script_s3_uri
}

output "landing_s3_path" {
  description = "S3 path where JSON extracts are written"
  value       = "s3://${data.aws_s3_bucket.landing.bucket}/${local.landing_prefix}"
}

output "logs_s3_path" {
  description = "S3 path for Glue Spark UI logs"
  value       = "s3://${data.aws_s3_bucket.logs.bucket}/${local.logs_prefix}"
}
