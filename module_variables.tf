###############################################################################
# variables.tf
###############################################################################

variable "project" {
  description = "Project name used as a prefix for all resource names."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region where resources are deployed."
  type        = string
  default     = "us-east-1"
}

# ─────────────────────────────────────────────────────────────────────────────
# SCHEMAS
# ─────────────────────────────────────────────────────────────────────────────
variable "schemas" {
  description = <<-EOT
    List of Aurora MySQL schema configurations. Each object must include:
      - name        : unique schema identifier (used in resource names)
      - db_host     : Aurora cluster endpoint
      - db_port     : MySQL port (usually 3306)
      - db_name     : database / schema name
      - db_user     : database username
      - db_password : database password (stored in Secrets Manager)
      - tables      : (optional) list of table names to extract; empty = all tables
  EOT
  type = list(object({
    name        = string
    db_host     = string
    db_port     = number
    db_name     = string
    db_user     = string
    db_password = string
    tables      = optional(list(string), [])
  }))

  validation {
    condition     = length(var.schemas) <= 36
    error_message = "A maximum of 36 schemas is supported by this module."
  }

  validation {
    condition     = length(var.schemas) > 0
    error_message = "At least one schema must be provided."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# S3
# ─────────────────────────────────────────────────────────────────────────────
variable "landing_bucket" {
  description = "Name of the S3 bucket where extracted data is stored (dev-landing)."
  type        = string
  default     = "dev-landing"
}

variable "scripts_bucket" {
  description = "S3 bucket where Glue PySpark scripts are stored."
  type        = string
}

variable "scripts_prefix" {
  description = "S3 key prefix inside scripts_bucket where job scripts are stored."
  type        = string
  default     = "glue-scripts"
}

variable "output_format" {
  description = "Output file format for extracted data (parquet or csv)."
  type        = string
  default     = "parquet"

  validation {
    condition     = contains(["parquet", "csv"], var.output_format)
    error_message = "output_format must be 'parquet' or 'csv'."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# GLUE JOB
# ─────────────────────────────────────────────────────────────────────────────
variable "glue_version" {
  description = "AWS Glue version."
  type        = string
  default     = "4.0"
}

variable "worker_type" {
  description = "Glue worker type (G.1X, G.2X, G.4X, G.8X)."
  type        = string
  default     = "G.1X"
}

variable "number_of_workers" {
  description = "Number of Glue workers per job."
  type        = number
  default     = 2
}

variable "job_timeout_minutes" {
  description = "Glue job timeout in minutes."
  type        = number
  default     = 60
}

variable "max_retries" {
  description = "Number of automatic retries on job failure."
  type        = number
  default     = 1
}

variable "enable_job_bookmark" {
  description = "Enable Glue job bookmarks for incremental loads."
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# NETWORKING  (Glue VPC connectivity to Aurora)
# ─────────────────────────────────────────────────────────────────────────────
variable "glue_subnet_id" {
  description = "Private subnet ID where Glue runs its elastic network interface."
  type        = string
}

variable "glue_security_group_ids" {
  description = "List of security group IDs attached to the Glue connection ENI."
  type        = list(string)
}

variable "availability_zone" {
  description = "AZ that matches the glue_subnet_id."
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# EVENTBRIDGE SCHEDULE
# ─────────────────────────────────────────────────────────────────────────────
variable "schedule_enabled" {
  description = "Set to false to disable all EventBridge rules (useful in lower envs)."
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# SECRETS MANAGER
# ─────────────────────────────────────────────────────────────────────────────
variable "secret_recovery_window_days" {
  description = "Days before a deleted secret is permanently purged."
  type        = number
  default     = 7
}

# ─────────────────────────────────────────────────────────────────────────────
# KMS
# ─────────────────────────────────────────────────────────────────────────────
variable "enable_kms_policy" {
  description = "Attach a KMS policy to the Glue role (required if CMK encryption is used)."
  type        = bool
  default     = false
}

# ─────────────────────────────────────────────────────────────────────────────
# TAGGING
# ─────────────────────────────────────────────────────────────────────────────
variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
