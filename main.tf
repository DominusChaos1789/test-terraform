# =============================================================================
# root/main.tf
# Environment : dev
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment and configure for remote state
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "cariai/batch/extractor/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Module instantiation
# ---------------------------------------------------------------------------
module "cariai_batch_extractor" {
  source = "./modules/glue_aurora_extractor"

  # Job identity
  job_name = "cariai-batch-extractor"

  # Connection / SSM
  ssm_connection_path = "augusta-nexa-dev/cariai/batch/connection"
  db_username         = var.db_username
  db_password         = var.db_password

  # Databases — 36 Aurora MySQL instances
  db_count       = 36
  database_names = var.database_names   # pass from terraform.tfvars

  # Networking
  subnet_id         = var.subnet_id
  security_group_id = "sg-05698cc6f2e6d512g"
  availability_zone = var.availability_zone

  # S3
  landing_bucket = "dev-landing"
  scripts_bucket = var.scripts_bucket

  # Extraction
  tables_to_extract = var.tables_to_extract   # [] = extract all tables
  output_format     = "parquet"

  # Compute
  worker_type       = "G.1X"
  number_of_workers = 10
  job_timeout_minutes = 120

  tags = {
    Project     = "cariai"
    Environment = "dev"
    Team        = "data-engineering"
    ManagedBy   = "terraform"
  }
}
