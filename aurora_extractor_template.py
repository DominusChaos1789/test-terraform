"""
glue_scripts/aurora_extractor_template.py
─────────────────────────────────────────
Generic PySpark Glue script that:
  1. Reads credentials from Secrets Manager (ARN passed as job arg)
  2. Connects to Aurora MySQL via JDBC
  3. Extracts one or all tables from a given schema
  4. Writes Parquet files to s3://dev-landing/<schema_name>/<table_name>/

Deploy one copy per schema, or use a single parameterised script.
"""

import sys
import json
import boto3
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F

# ── Job arguments injected by Terraform ─────────────────────────────────────
args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "SOURCE_SCHEMA",
    "SOURCE_HOST",
    "SOURCE_PORT",
    "SOURCE_DB",
    "SECRET_ARN",
    "TARGET_BUCKET",
    "TARGET_PREFIX",
    "TARGET_FORMAT",
    "TABLES_TO_EXTRACT",   # comma-separated list; empty string = all tables
])

sc          = SparkContext()
glue_ctx    = GlueContext(sc)
spark       = glue_ctx.spark_session
job         = Job(glue_ctx)
job.init(args["JOB_NAME"], args)

# ── Fetch credentials from Secrets Manager ───────────────────────────────────
secrets_client = boto3.client("secretsmanager")
secret_value   = secrets_client.get_secret_value(SecretId=args["SECRET_ARN"])
credentials    = json.loads(secret_value["SecretString"])

jdbc_url = (
    f"jdbc:mysql://{args['SOURCE_HOST']}:{args['SOURCE_PORT']}"
    f"/{args['SOURCE_DB']}?useSSL=true&requireSSL=true"
)

jdbc_props = {
    "user":                 credentials["username"],
    "password":             credentials["password"],
    "driver":               "com.mysql.cj.jdbc.Driver",
    "fetchsize":            "10000",
    "sessionInitStatement": f"USE `{args['SOURCE_DB']}`",
}

# ── Resolve table list ────────────────────────────────────────────────────────
requested_tables = [t.strip() for t in args["TABLES_TO_EXTRACT"].split(",") if t.strip()]

if not requested_tables:
    # Discover all tables in the schema dynamically
    query = f"""
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = '{args["SOURCE_DB"]}'
          AND table_type   = 'BASE TABLE'
    """
    tables_df      = spark.read.jdbc(url=jdbc_url, table=f"({query}) t", properties=jdbc_props)
    requested_tables = [row["table_name"] for row in tables_df.collect()]

print(f"[{args['SOURCE_SCHEMA']}] Extracting {len(requested_tables)} table(s): {requested_tables}")

# ── Extract & load each table ─────────────────────────────────────────────────
for table in requested_tables:
    print(f"  → Extracting table: {table}")

    df = (
        spark.read.jdbc(
            url        = jdbc_url,
            table      = f"`{args['SOURCE_DB']}`.`{table}`",
            properties = jdbc_props,
        )
        .withColumn("_extraction_ts", F.current_timestamp())
        .withColumn("_source_schema", F.lit(args["SOURCE_SCHEMA"]))
        .withColumn("_source_table",  F.lit(table))
    )

    target_path = (
        f"s3://{args['TARGET_BUCKET']}/{args['TARGET_PREFIX']}/{table}/"
    )

    writer = df.write.mode("overwrite")

    if args["TARGET_FORMAT"].lower() == "parquet":
        writer.parquet(target_path)
    else:
        writer.option("header", "true").csv(target_path)

    print(f"     Written to {target_path}  ({df.count()} rows)")

job.commit()
print(f"[{args['SOURCE_SCHEMA']}] Extraction complete.")
