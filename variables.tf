# =============================================================================
# root/variables.tf
# =============================================================================

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for Glue connection ENIs."
}

variable "availability_zone" {
  type        = string
  description = "AZ matching the subnet (e.g. us-east-1a)."
}

variable "scripts_bucket" {
  type        = string
  description = "S3 bucket that stores Glue scripts and temp output."
}

variable "database_names" {
  type        = list(string)
  description = "36 Aurora MySQL schema names, one per instance."
}

variable "tables_to_extract" {
  type        = list(string)
  description = "Specific tables to extract. Leave empty to extract ALL tables."
  default     = []
}
