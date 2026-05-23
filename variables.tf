variable "environment" {
  description = "Deployment environment (dev / staging / prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region where resources are deployed."
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "ID of the VPC that contains the Aurora clusters and the Glue connection subnet."
  type        = string
}

variable "glue_extra_jars" {
  description = "Optional list of extra JAR S3 URIs to attach to the Glue job (e.g. MySQL JDBC driver)."
  type        = list(string)
  default     = []
}

variable "enable_bookmark" {
  description = "Enable Glue job bookmarks to support incremental loads."
  type        = bool
  default     = false
}

variable "additional_job_args" {
  description = "Map of extra --key=value arguments merged into the Glue job default arguments."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days."
  type        = number
  default     = 14
}
