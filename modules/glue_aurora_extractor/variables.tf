# =============================================================================
# variables.tf — glue_aurora_extractor module
# =============================================================================

# ---------------------------------------------------------------------------
# Glue job identity
# ---------------------------------------------------------------------------
variable "job_name" {
  type        = string
  description = "Name of the Glue job."
  default     = "cariai-batch-extractor"
}

# ---------------------------------------------------------------------------
# Database connectivity
# ---------------------------------------------------------------------------
variable "db_count" {
  type        = number
  description = "Total number of Aurora MySQL databases to extract from."
  default     = 36

  validation {
    condition     = var.db_count > 0
    error_message = "db_count must be at least 1."
  }
}

variable "database_names" {
  type        = list(string)
  description = <<-EOT
    Ordered list of database/schema names — one per Aurora instance.
    Length must match db_count.
    Example: ["cariai_db_00", "cariai_db_01", ... "cariai_db_35"]
  EOT

  validation {
    condition     = length(var.database_names) == var.db_count
    error_message = "The length of database_names must equal db_count."
  }
}

variable "db_username" {
  type        = string
  description = "Master username for Aurora MySQL connections."
  sensitive   = true
}

variable "db_password" {
  type        = string
  description = "Master password for Aurora MySQL connections."
  sensitive   = true
}

variable "ssm_connection_path" {
  type        = string
  description = "SSM Parameter Store path that holds the connection JSON."
  default     = "augusta-nexa-dev/cariai/batch/connection"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "subnet_id" {
  type        = string
  description = "Subnet ID where Glue ENIs will be placed."
}

variable "security_group_id" {
  type        = string
  description = "Security group attached to Glue connections."
  default     = "sg-05698cc6f2e6d512g"
}

variable "availability_zone" {
  type        = string
  description = "AZ that matches the subnet."
}

# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------
variable "landing_bucket" {
  type        = string
  description = "S3 bucket where extracted data is stored."
  default     = "dev-landing"
}

variable "scripts_bucket" {
  type        = string
  description = "S3 bucket used to host Glue scripts and temp files."
}

# ---------------------------------------------------------------------------
# Extraction settings
# ---------------------------------------------------------------------------
variable "tables_to_extract" {
  type        = list(string)
  description = "List of table names to extract from every database."
  default     = []
}

variable "output_format" {
  type        = string
  description = "Output format written to S3 (parquet | csv | json)."
  default     = "parquet"

  validation {
    condition     = contains(["parquet", "csv", "json"], var.output_format)
    error_message = "output_format must be one of: parquet, csv, json."
  }
}

# ---------------------------------------------------------------------------
# Glue compute settings
# ---------------------------------------------------------------------------
variable "worker_type" {
  type        = string
  description = "Glue worker type (G.1X | G.2X | G.025X)."
  default     = "G.1X"

  validation {
    condition     = contains(["G.1X", "G.2X", "G.025X"], var.worker_type)
    error_message = "worker_type must be G.1X, G.2X, or G.025X."
  }
}

variable "number_of_workers" {
  type        = number
  description = "Number of Glue workers to allocate."
  default     = 10
}

variable "job_timeout_minutes" {
  type        = number
  description = "Maximum job run time in minutes before Glue forcefully stops it."
  default     = 120
}

variable "max_concurrent_runs" {
  type        = number
  description = "Maximum concurrent runs of this Glue job."
  default     = 1
}

# ---------------------------------------------------------------------------
# Tagging
# ---------------------------------------------------------------------------
variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources created by this module."
  default = {
    Project     = "cariai"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
