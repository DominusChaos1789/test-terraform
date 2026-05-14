variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# ─── Aurora connection (shared host/port) ───────────────────────────────────
variable "aurora_host" {
  description = "Aurora MySQL cluster endpoint (shared across all schemas)"
  type        = string
}

variable "aurora_port" {
  description = "Aurora MySQL port"
  type        = number
  default     = 3306
}

variable "aurora_vpc_id" {
  description = "VPC ID where Aurora resides"
  type        = string
}

variable "aurora_subnet_ids" {
  description = "List of subnet IDs for the Glue connection"
  type        = list(string)
}

variable "aurora_security_group_ids" {
  description = "Security group IDs allowed to reach Aurora"
  type        = list(string)
}

# ─── 36 CarIAI WhatsApp schemas ─────────────────────────────────────────────
# Each entry represents one WhatsApp-instance schema with its own credentials.
variable "cariai_schemas" {
  description = "List of 36 CarIAI WhatsApp schema configurations"
  type = list(object({
    schema_name = string # e.g. "cariai_wa_001"
    username    = string
    password    = string # Prefer referencing Secrets Manager ARNs in production
  }))
  sensitive = true

  validation {
    condition     = length(var.cariai_schemas) == 36
    error_message = "Exactly 36 CarIAI schemas must be provided."
  }
}

# ─── S3 buckets (names only – ARNs derived via data sources) ────────────────
variable "landing_bucket_name" {
  description = "S3 bucket name for raw landing data"
  type        = string
  default     = "dev-landing"
}

variable "logs_bucket_name" {
  description = "S3 bucket name for Glue job logs"
  type        = string
  default     = "dev-logs"
}

variable "resources_bucket_name" {
  description = "S3 bucket name for Glue scripts and resources"
  type        = string
  default     = "dev-resources"
}

variable "cariai_prefix" {
  description = "S3 prefix used across all buckets for CarIAI assets"
  type        = string
  default     = "cariai"
}

# ─── Glue job settings ──────────────────────────────────────────────────────
variable "glue_version" {
  description = "AWS Glue version"
  type        = string
  default     = "4.0"
}

variable "python_version" {
  description = "Python version for the Glue job"
  type        = string
  default     = "3"
}

variable "number_of_workers" {
  description = "Number of Glue workers"
  type        = number
  default     = 2
}

variable "worker_type" {
  description = "Glue worker type (Standard | G.1X | G.2X | G.025X)"
  type        = string
  default     = "G.1X"
}

variable "job_timeout_minutes" {
  description = "Glue job timeout in minutes"
  type        = number
  default     = 120
}

variable "max_retries" {
  description = "Maximum number of retries on job failure"
  type        = number
  default     = 0
}

# ─── Scheduling (COT = UTC-5, so 5 AM COT = 10:00 UTC) ─────────────────────
variable "schedule_cron" {
  description = "EventBridge cron expression in UTC (default: 10:00 UTC = 05:00 COT)"
  type        = string
  default     = "cron(0 10 * * ? *)"
}

variable "schedule_enabled" {
  description = "Whether the EventBridge schedule is enabled"
  type        = bool
  default     = true
}

# ─── Tags ───────────────────────────────────────────────────────────────────
variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default = {
    Project     = "CarIAI"
    ManagedBy   = "Terraform"
    Application = "WhatsApp-Extractor"
  }
}
