# cariai-batch-extractor — Terraform Module

Deploys a complete AWS Glue extraction pipeline that reads from **36 Aurora MySQL** databases and writes Parquet files to the `dev-landing` S3 bucket, triggered daily at **05:00 COT** via EventBridge Scheduler.

## File structure

```
.
├── versions.tf        # Terraform + provider pin
├── variables.tf       # Input variables
├── locals.tf          # All computed/static values (single source of truth)
├── data.tf            # Remote lookups: SSM, S3, IAM policy documents
├── iam.tf             # IAM roles + policies (Glue + Scheduler)
├── glue.tf            # Glue connection, job, EventBridge schedule
├── s3.tf              # S3 object upload (Glue script)
├── outputs.tf         # Exported values
└── scripts/
    └── extractor.py   # PySpark ETL script uploaded to S3
```

## Resources created

| Resource | Name |
|---|---|
| `aws_glue_connection` | `cariai-batch-extractor-jdbc` |
| `aws_glue_job` | `cariai-batch-extractor` |
| `aws_iam_role` (Glue) | `cariai-batch-extractor-glue-role` |
| `aws_iam_role` (Scheduler) | `cariai-batch-extractor-scheduler-role` |
| `aws_scheduler_schedule` | `cariai-batch-extractor-daily-trigger` |
| `aws_cloudwatch_log_group` | `/aws-glue/jobs/cariai-batch-extractor` |
| `aws_s3_object` (script) | `dev-landing/glue-scripts/cariai-batch-extractor.py` |

## Key design decisions

### Connection credentials
The `aws_glue_connection` resource requires `USERNAME`/`PASSWORD` keys — they are set to `"placeholder"`. **Real credentials are fetched at runtime** by the Python script from AWS Secrets Manager (`augusta-nexa-dev/cariai/batch/db-credentials`). Update the path in `scripts/extractor.py` to match your secrets layout.

### 36 databases as a job argument
The list of database names lives in `locals.tf → local.db_list`. The Python script receives them as a comma-separated string via `--db_list`, iterates over each, discovers tables dynamically, and writes Parquet partitions to:
```
s3://dev-landing/raw/<db_name>/<table_name>/
```

### Schedule timezone
EventBridge Scheduler supports IANA timezone names. The schedule is set to `America/Bogota` (COT, UTC-5) at cron `0 10 * * ? *` — which equals exactly 05:00 COT regardless of DST.

### Error handling
A single failing table does **not** abort the job. Failures are logged to CloudWatch and the job continues with the remaining tables/databases.

## Usage

```hcl
module "glue_extractor" {
  source      = "./terraform-glue-module"
  environment = "dev"
  aws_region  = "us-east-1"
  vpc_id      = "vpc-0abc1234def56789a"
}
```

## Required IAM permissions to deploy

The Terraform executor needs permissions to create IAM roles, Glue jobs/connections, EventBridge schedules, CloudWatch log groups, and S3 objects.

## Pre-requisites

1. `dev-landing` S3 bucket must exist before `terraform apply`.
2. SSM parameter `augusta-nexa-dev/cariai/batch/connection` must exist with the JSON payload.
3. Secrets Manager secret `augusta-nexa-dev/cariai/batch/db-credentials` must contain `{"username": "...", "password": "..."}`.
4. The MySQL JDBC driver JAR must be available in S3 if not bundled. Pass its URI via `var.glue_extra_jars`.
5. The subnet and security group must allow outbound TCP to Aurora on port 3306.
