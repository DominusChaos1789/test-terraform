output "glue_job_name" {
  description = "Name of the created Glue job."
  value       = aws_glue_job.extractor.name
}

output "glue_job_arn" {
  description = "ARN of the Glue job."
  value       = "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:job/${aws_glue_job.extractor.name}"
}

output "glue_connection_name" {
  description = "Name of the JDBC Glue connection."
  value       = aws_glue_connection.aurora_mysql.name
}

output "glue_role_arn" {
  description = "ARN of the IAM role attached to the Glue job."
  value       = aws_iam_role.glue_job.arn
}

output "scheduler_name" {
  description = "EventBridge Scheduler schedule name."
  value       = aws_scheduler_schedule.glue_job_trigger.name
}

output "script_s3_uri" {
  description = "S3 URI of the uploaded Glue script."
  value       = "s3://${local.landing_bucket_name}/${local.script_s3_key}"
}

output "jdbc_base_url" {
  description = "JDBC base URL derived from Parameter Store (no database name appended)."
  value       = local.jdbc_url
  sensitive   = true
}
