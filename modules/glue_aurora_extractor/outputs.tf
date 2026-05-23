# =============================================================================
# outputs.tf — glue_aurora_extractor module
# =============================================================================

output "glue_job_name" {
  description = "Name of the provisioned Glue job."
  value       = aws_glue_job.extractor.name
}

output "glue_job_arn" {
  description = "ARN of the provisioned Glue job."
  value       = aws_glue_job.extractor.arn
}

output "glue_role_arn" {
  description = "ARN of the IAM role attached to the Glue job."
  value       = aws_iam_role.glue_job.arn
}

output "connection_names" {
  description = "List of Glue connection names created (one per DB)."
  value       = [for i in local.db_indexes : aws_glue_connection.aurora_db[tostring(i)].name]
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge schedule rule."
  value       = aws_cloudwatch_event_rule.glue_schedule.arn
}

output "script_s3_uri" {
  description = "S3 URI of the uploaded PySpark extraction script."
  value       = "s3://${var.scripts_bucket}/glue-scripts/${var.job_name}/extractor.py"
}
