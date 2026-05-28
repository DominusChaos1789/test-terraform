locals {
  # ── Job identity ─────────────────────────────────────────────────────────────
  job_name        = "cariai-batch-extractor"
  job_description = "Extracts CariAI datasets from 36 Aurora MySQL databases into S3 dev-landing"

  # ── Network ───────────────────────────────────────────────────────────────────
  subnet_id          = "subnet-05698cc6f2e6d512g"
  security_group_ids = ["sg-05698cc6f2e6d512g"]

  # ── SSM paths ─────────────────────────────────────────────────────────────────
  # Shared JDBC config  →  {"type":"JDBC","host":"10.32.127.4","port":"3306"}
  ssm_connection_path = "augusta-nexa-dev/cariai/batch/connection"

  # Table/dataset catalog  →  {"dim tables":[...],"fact tables":[...]}
  ssm_datasets_path   = "augusta-nexa-dev/cariai/batch/datasets"

  connection_name = "${local.job_name}-jdbc"

  # ── S3 ────────────────────────────────────────────────────────────────────────
  landing_bucket_name = "dev-landing"
  scripts_prefix      = "glue-scripts"
  script_s3_key       = "${local.scripts_prefix}/${local.job_name}.py"

  # ── Schedule  —  5 AM COT (America/Bogota = UTC-5  →  10:00 UTC) ──────────────
  schedule_expression = "cron(0 10 * * ? *)"

  # ── Glue job settings ─────────────────────────────────────────────────────────
  glue_version      = "4.0"
  python_version    = "3"
  worker_type       = "G.1X"
  number_of_workers = 5
  max_retries       = 1
  timeout_minutes   = 180   # bumped: 36 DBs × multiple tables with date filters

  # ── Per-database credential map ───────────────────────────────────────────────
  # Secret path convention: /<stack_id>/cariai/bdd/<connection_indicator>
  # Secret JSON format:     {"user": "...", "password": "..."}
  #
  # Each Aurora database has a unique connection indicator (and therefore unique
  # credentials). Replace the keys below with your real DB identifiers and
  # adjust the connection_indicator values to match what is in Secrets Manager.
  #
  # Example indicators already confirmed:  avl-sac  |  bdb-sac  |  bdo-sac
  databases = {
    avl_sac_01 = { stack_id = "augusta-nexa-dev", connection_indicator = "avl-sac" }
    bdb_sac_01 = { stack_id = "augusta-nexa-dev", connection_indicator = "bdb-sac" }
    bdo_sac_01 = { stack_id = "augusta-nexa-dev", connection_indicator = "bdo-sac" }
    # ── Add remaining 33 databases here following the same pattern ────────────
    # db_004     = { stack_id = "augusta-nexa-dev", connection_indicator = "xxx-sac" }
    # ...
  }

  # Derive secret paths from the map so they are never duplicated elsewhere
  db_secret_paths = {
    for db_key, cfg in local.databases :
    db_key => "/${cfg.stack_id}/cariai/bdd/${cfg.connection_indicator}"
  }

  # Flat "db_key::secret_path" string passed as a single Glue job argument.
  # Python splits on "," then "::" to reconstruct the map at runtime.
  db_secret_pairs = join(",", [
    for db_key, secret_path in local.db_secret_paths :
    "${db_key}::${secret_path}"
  ])

  # ARN patterns used for the IAM least-privilege policy (covers rotation suffixes)
  db_secret_arns = [
    for db_key, secret_path in local.db_secret_paths :
    "arn:aws:secretsmanager:*:*:secret:${secret_path}*"
  ]

  common_tags = {
    Project     = "cariai"
    Environment = var.environment
    ManagedBy   = "terraform"
    Team        = "data-engineering"
  }
}
