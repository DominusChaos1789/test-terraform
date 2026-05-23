# cariai-batch-extractor — Terraform Module

Provisions all AWS resources needed to extract data from **36 Aurora MySQL
databases** via AWS Glue and land the results in S3, triggered on a daily
schedule at **05:00 COT (10:00 UTC)**.

---

## Architecture

```
EventBridge Rule (cron 10:00 UTC)
        │
        ▼
  IAM Role (EventBridge → Glue)
        │
        ▼
  Glue Job: cariai-batch-extractor
        │   (PySpark 4.0, G.1X workers)
        │
        ├── SSM Parameter Store ──► connection JSON (host, port, type)
        │   augusta-nexa-dev/cariai/batch/connection
        │
        ├── Glue Connections (×36) ──► Aurora MySQL via JDBC
        │   cariai-batch-extractor-conn-db0 … conn-db35
        │
        └── S3 dev-landing
              └── <database>/<table>/extraction_date=YYYY-MM-DD/
                      └── part-00000.snappy.parquet
```

---

## Prerequisites

| Resource | Notes |
|---|---|
| S3 bucket `dev-landing` | Must exist before `terraform apply` |
| S3 scripts bucket | Specified in `scripts_bucket` variable |
| SSM Parameter | `augusta-nexa-dev/cariai/batch/connection` must exist as a JSON string |
| VPC / Subnet | Subnet must have a route to the Aurora endpoints |
| Security Group | `sg-05698cc6f2e6d512g` must allow outbound 3306 to Aurora |

---

## Module Structure

```
terraform-glue-cariai/
├── main.tf                          # Root — calls the module
├── variables.tf
├── outputs.tf
├── terraform.tfvars.example
└── modules/
    └── glue_aurora_extractor/
        ├── main.tf                  # All resource definitions
        ├── variables.tf
        ├── outputs.tf
        └── scripts/
            └── extractor.py        # PySpark extraction job
```

---

## Quick Start

```bash
# 1. Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set real subnet_id, scripts_bucket, db credentials

# 2. Initialise
terraform init

# 3. Plan
terraform plan -out=tfplan

# 4. Apply
terraform apply tfplan
```

---

## Key Variables

| Variable | Default | Description |
|---|---|---|
| `job_name` | `cariai-batch-extractor` | Glue job name |
| `db_count` | `36` | Number of Aurora databases |
| `database_names` | *(required)* | Ordered list of 36 schema names |
| `landing_bucket` | `dev-landing` | Target S3 bucket |
| `scripts_bucket` | *(required)* | S3 bucket for Glue scripts |
| `ssm_connection_path` | `augusta-nexa-dev/cariai/batch/connection` | SSM path |
| `security_group_id` | `sg-05698cc6f2e6d512g` | Security group for Glue connections |
| `subnet_id` | *(required)* | Subnet for Glue ENIs |
| `worker_type` | `G.1X` | Glue worker type |
| `number_of_workers` | `10` | Worker count |
| `output_format` | `parquet` | Output format (parquet / csv / json) |
| `tables_to_extract` | `[]` | Specific tables; empty = all |

---

## S3 Output Layout

```
s3://dev-landing/
└── cariai_db_00/
│   └── orders/
│       └── extraction_date=2025-09-01/
│           └── part-00000.snappy.parquet
└── cariai_db_01/
    └── customers/
        └── extraction_date=2025-09-01/
            └── part-00000.snappy.parquet
```

---

## Schedule

The EventBridge rule uses:

```
cron(0 10 * * ? *)   →  10:00 UTC  =  05:00 COT (UTC-5)
```

> **Note:** Colombia does not observe Daylight Saving Time, so COT is always UTC-5.

---

## Notes & Gotchas

- **Security Group ID vs Subnet ID** — the value `sg-05698cc6f2e6d512g` is a
  security group ID (SG). A separate `subnet_id` variable accepts the actual
  subnet ID (`subnet-xxxxxxxxx`). Both are required for Glue physical connection
  requirements.
- **DB credentials** — stored as Glue connection properties. Consider rotating
  via AWS Secrets Manager and a Lambda rotation function for production.
- **36 Glue Connections** — each connection is a separate AWS resource. The
  `for_each` loop creates them in parallel; `terraform plan` will show 36
  `aws_glue_connection` resources.
- **Table discovery** — when `tables_to_extract = []`, the PySpark script
  queries `information_schema.tables` at runtime to discover all tables. Ensure
  the DB user has `SELECT` on `information_schema`.
