# =============================================================================
# root/outputs.tf
# =============================================================================

output "glue_job_name" {
  value = module.cariai_batch_extractor.glue_job_name
}

output "glue_job_arn" {
  value = module.cariai_batch_extractor.glue_job_arn
}

output "eventbridge_rule_arn" {
  value = module.cariai_batch_extractor.eventbridge_rule_arn
}

output "script_s3_uri" {
  value = module.cariai_batch_extractor.script_s3_uri
}

output "connection_names" {
  value = module.cariai_batch_extractor.connection_names
}
