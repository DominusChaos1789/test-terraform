locals {
  # Job identity
  job_name        = "cariai-batch-extractor"
  job_description = "Extracts data from 36 Aurora MySQL databases and lands it in S3"

  # Network
  subnet_id          = "subnet-05698cc6f2e6d512g"   # private subnet hosting the Glue ENI
  security_group_ids = ["sg-05698cc6f2e6d512g"]      # Glue connection security group

  # Connection / Parameter Store
  ssm_parameter_path = "augusta-nexa-dev/cariai/batch/connection"
  connection_name    = "${local.job_name}-jdbc"

  # S3
  landing_bucket_name = "dev-landing"
  scripts_prefix      = "glue-scripts"
  script_s3_key       = "${local.scripts_prefix}/${local.job_name}.py"

  # Schedule — 5 AM COT = 10 AM UTC (COT = UTC-5)
  schedule_expression = "cron(0 10 * * ? *)"

  # Glue job settings
  glue_version      = "4.0"
  python_version    = "3"
  worker_type       = "G.1X"
  number_of_workers = 5      # tune based on 36 DBs parallelism needs
  max_retries       = 1
  timeout_minutes   = 120

  # List of 36 Aurora MySQL database identifiers passed as a job argument.
  # Stored here so they are centrally managed; the Python script reads
  # --db_list and fans out the extraction.
  db_list = join(",", [
    "db_001", "db_002", "db_003", "db_004", "db_005", "db_006",
    "db_007", "db_008", "db_009", "db_010", "db_011", "db_012",
    "db_013", "db_014", "db_015", "db_016", "db_017", "db_018",
    "db_019", "db_020", "db_021", "db_022", "db_023", "db_024",
    "db_025", "db_026", "db_027", "db_028", "db_029", "db_030",
    "db_031", "db_032", "db_033", "db_034", "db_035", "db_036",
  ])

  common_tags = {
    Project     = "cariai"
    Environment = var.environment
    ManagedBy   = "terraform"
    Team        = "data-engineering"
  }
}
