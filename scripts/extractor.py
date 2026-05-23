"""
cariai-batch-extractor — Glue ETL script
==========================================
Reads connection details from AWS Parameter Store, then iterates over
every database in --db_list, extracting all tables via JDBC and writing
Parquet partitions to s3://<landing_bucket>/raw/<db_name>/<table_name>/.

Job arguments (injected by Terraform default_arguments):
  --ssm_parameter_path   Path in Parameter Store with JDBC JSON config
  --s3_landing_bucket    Target S3 bucket name (dev-landing)
  --db_list              Comma-separated list of 36 database names
  --aws_region           AWS region
  --JOB_NAME             Glue built-in
"""

import sys
import json
import logging

import boto3
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── Job arguments ─────────────────────────────────────────────────────────────
args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "ssm_parameter_path",
        "s3_landing_bucket",
        "db_list",
        "aws_region",
    ],
)

JOB_NAME        = args["JOB_NAME"]
SSM_PATH        = args["ssm_parameter_path"]
LANDING_BUCKET  = args["s3_landing_bucket"]
DB_LIST         = [db.strip() for db in args["db_list"].split(",") if db.strip()]
AWS_REGION      = args["aws_region"]

# ── Spark / Glue context ──────────────────────────────────────────────────────
sc          = SparkContext()
glue_ctx    = GlueContext(sc)
spark       = glue_ctx.spark_session
job         = Job(glue_ctx)
job.init(JOB_NAME, args)

# ── Read credentials & connection config from Parameter Store ─────────────────
def get_connection_config(ssm_path: str, region: str) -> dict:
    """Return parsed JSON from SSM Parameter Store."""
    ssm    = boto3.client("ssm", region_name=region)
    resp   = ssm.get_parameter(Name=ssm_path, WithDecryption=True)
    config = json.loads(resp["Parameter"]["Value"])
    logger.info("Connection config loaded from SSM (host=%s, port=%s)",
                config.get("host"), config.get("port"))
    return config


def get_db_credentials(region: str) -> tuple[str, str]:
    """
    Retrieve DB username and password from Secrets Manager or a dedicated
    SSM parameter.  Update the path below to match your secrets layout.
    """
    sm     = boto3.client("secretsmanager", region_name=region)
    secret = sm.get_secret_value(SecretId="augusta-nexa-dev/cariai/batch/db-credentials")
    creds  = json.loads(secret["SecretString"])
    return creds["username"], creds["password"]


conn_cfg           = get_connection_config(SSM_PATH, AWS_REGION)
JDBC_HOST          = conn_cfg["host"]
JDBC_PORT          = str(conn_cfg["port"])
DB_USERNAME, DB_PASSWORD = get_db_credentials(AWS_REGION)

# ── Helper — extract one database ────────────────────────────────────────────
def extract_database(db_name: str) -> None:
    jdbc_url = f"jdbc:mysql://{JDBC_HOST}:{JDBC_PORT}/{db_name}"
    logger.info("Starting extraction: database=%s  url=%s", db_name, jdbc_url)

    # Discover all tables in the database
    tables_df = (
        spark.read
        .format("jdbc")
        .option("url",      jdbc_url)
        .option("user",     DB_USERNAME)
        .option("password", DB_PASSWORD)
        .option("driver",   "com.mysql.cj.jdbc.Driver")
        .option("query",    "SELECT table_name FROM information_schema.tables "
                            "WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'")
        .load()
    )

    tables = [row["table_name"] for row in tables_df.collect()]
    logger.info("Found %d tables in %s", len(tables), db_name)

    for table in tables:
        s3_path = f"s3://{LANDING_BUCKET}/raw/{db_name}/{table}/"
        try:
            df = (
                spark.read
                .format("jdbc")
                .option("url",          jdbc_url)
                .option("dbtable",      table)
                .option("user",         DB_USERNAME)
                .option("password",     DB_PASSWORD)
                .option("driver",       "com.mysql.cj.jdbc.Driver")
                .option("fetchsize",    "10000")
                .option("numPartitions","4")
                .load()
            )

            row_count = df.count()
            (
                df.write
                .mode("overwrite")
                .parquet(s3_path)
            )
            logger.info("  ✓ %s.%s → %s (%d rows)", db_name, table, s3_path, row_count)

        except Exception as exc:  # noqa: BLE001
            # Log and continue — one failing table must not abort the whole job
            logger.error("  ✗ %s.%s failed: %s", db_name, table, exc)


# ── Main — iterate over all 36 databases ─────────────────────────────────────
logger.info("Extraction started — %d databases to process", len(DB_LIST))

failed_dbs = []
for db in DB_LIST:
    try:
        extract_database(db)
    except Exception as exc:  # noqa: BLE001
        logger.error("Database %s failed entirely: %s", db, exc)
        failed_dbs.append(db)

if failed_dbs:
    logger.warning("Extraction finished with %d failed databases: %s",
                   len(failed_dbs), failed_dbs)
else:
    logger.info("Extraction completed successfully for all %d databases.", len(DB_LIST))

job.commit()
