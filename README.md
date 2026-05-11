# Terraform Module: `glue_aurora_extractor`

Provisions AWS infrastructure to extract data from **up to 36 Aurora MySQL schemas** into S3, triggered daily at **05:00 COT** via EventBridge.

---

## Architecture

```
EventBridge Rule (cron 10:00 UTC = 05:00 COT)
        │
        ▼  (per schema)
  AWS Glue Job  ──── Glue Connection ──▶  Aurora MySQL (schema_N)
        │                                   │
        │  reads credentials from           │
        ▼                                   │
  Secrets Manager                           │
        │                                   │
        ▼                                   │
  s3://dev-landing/<schema_name>/<table>/  ◀─┘  (Parquet output)
        │
        ▼
  Glue Data Catalog (database per schema)
```

## File Structure

```
modules/glue_aurora_extractor/
├── main.tf        # Glue jobs, connections, EventBridge rules, Secrets Manager
├── iam.tf         # IAM roles and policy attachments
├── data.tf        # ALL IAM policy JSON documents + data sources
├── variables.tf   # Input variables
├── outputs.tf     # Output values
└── versions.tf    # Provider requirements
```

## Resources Created (per schema)

| Resource | Count |
|---|---|
| `aws_secretsmanager_secret` | 1 per schema |
| `aws_glue_connection` (JDBC) | 1 per schema |
| `aws_glue_job` | 1 per schema |
| `aws_cloudwatch_event_rule` | 1 per schema |
| `aws_cloudwatch_event_target` | 1 per schema |
| `aws_glue_catalog_database` | 1 per schema |

Shared across all schemas:

| Resource | Count |
|---|---|
| `aws_iam_role` (Glue) | 1 |
| `aws_iam_role` (EventBridge) | 1 |
| All IAM policies (inline) | 1 set |

---

## Schedule

**05:00 COT** (Colombia Time, UTC-5) = **10:00 UTC**

EventBridge cron expression: `cron(0 10 * * ? *)`

> Colombia does **not** observe daylight saving time, so this offset is constant year-round.

---

## Usage

```hcl
module "glue_aurora_extractor" {
  source = "./modules/glue_aurora_extractor"

  project        = "data-platform"
  environment    = "dev"
  aws_region     = "us-east-1"
  landing_bucket = "dev-landing"
  scripts_bucket = "my-glue-scripts-bucket"

  glue_subnet_id          = "subnet-xxxxxxxx"
  glue_security_group_ids = ["sg-xxxxxxxx"]
  availability_zone       = "us-east-1a"

  schemas = [
    {
      name        = "schema_01"
      db_host     = "cluster-01.cluster-xxxx.us-east-1.rds.amazonaws.com"
      db_port     = 3306
      db_name     = "schema_01"
      db_user     = "etl_user_01"
      db_password = var.schema_passwords["schema_01"]
      tables      = []   # empty = all tables
    },
    # ... up to 36 schemas
  ]

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
```

---

## Security Notes

1. **Passwords are never hard-coded.** Store them in Terraform workspace variables or pass via `TF_VAR_schema_passwords`.
2. Secrets Manager holds the full DB credentials; the Glue job reads them at runtime via `SECRET_ARN`.
3. The IAM policies in `data.tf` follow least-privilege: S3 write is scoped to `dev-landing/*` only.
4. Enable `enable_kms_policy = true` if your S3 bucket or Secrets Manager uses a CMK.

---

## Deploying the Glue Scripts

Upload the PySpark script to S3 before running the jobs:

```bash
aws s3 cp glue_scripts/aurora_extractor_template.py \
  s3://<scripts_bucket>/glue-scripts/aurora-extractor/<schema_name>_extractor.py
```

Or automate it with a `null_resource` + `aws s3 cp` in your root module.

---

## Outputs

| Name | Description |
|---|---|
| `glue_job_names` | Map of schema → Glue job name |
| `glue_job_arns` | Map of schema → Glue job ARN |
| `glue_role_arn` | Shared Glue IAM role ARN |
| `eventbridge_rule_arns` | Map of schema → EventBridge rule ARN |
| `secret_arns` | Map of schema → Secrets Manager ARN (sensitive) |
| `glue_catalog_databases` | Map of schema → Glue catalog DB name |
