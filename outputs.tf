###############################################################################
# outputs.tf
###############################################################################

output "glue_job_names" {
  description = "Map of schema name → Glue job name."
  value       = { for k, j in aws_glue_job.extractor : k => j.name }
}

output "glue_job_arns" {
  description = "Map of schema name → Glue job ARN."
  value = {
    for k, j in aws_glue_job.extractor :
    k => "arn:${data.aws_partition.current.partition}:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:job/${j.name}"
  }
}

output "glue_role_arn" {
  description = "ARN of the shared IAM role used by all Glue extractor jobs."
  value       = aws_iam_role.glue_role.arn
}

output "eventbridge_role_arn" {
  description = "ARN of the IAM role used by EventBridge to trigger Glue jobs."
  value       = aws_iam_role.eventbridge_role.arn
}

output "eventbridge_rule_arns" {
  description = "Map of schema name → EventBridge rule ARN."
  value       = { for k, r in aws_cloudwatch_event_rule.glue_schedule : k => r.arn }
}

output "secret_arns" {
  description = "Map of schema name → Secrets Manager secret ARN."
  value       = { for k, s in aws_secretsmanager_secret.schema_credentials : k => s.arn }
  sensitive   = true
}

output "glue_catalog_databases" {
  description = "Map of schema name → Glue Catalog database name."
  value       = { for k, db in aws_glue_catalog_database.schema_db : k => db.name }
}
