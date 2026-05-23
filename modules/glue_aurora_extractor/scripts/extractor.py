"""
extractor.py — PySpark / AWS Glue 4.0
======================================
Extracts tables from N Aurora MySQL databases (via JDBC) and writes the result
as Parquet (or CSV/JSON) to the dev-landing S3 bucket.

Partition layout in S3:
  s3://<LANDING_BUCKET>/<database_name>/<table_name>/
      extraction_date=YYYY-MM-DD/
          part-00000.snappy.parquet

Job arguments (passed via Glue --default_arguments):
  --DB_COUNT             : int   — number of Aurora databases
  --DATABASE_NAMES       : str   — comma-separated list of schema names
  --LANDING_BUCKET       : str   — target S3 bucket
  --SSM_CONNECTION_PATH  : str   — SSM path for connection JSON
  --CONNECTION_NAME_PREFIX: str  — prefix used to build Glue connection names
  --OUTPUT_FORMAT        : str   — parquet | csv | json
  --TABLES_TO_EXTRACT    : str   — comma-separated table names (empty = all)
"""

import sys
import json
import boto3
from datetime import date
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "DB_COUNT",
        "DATABASE_NAMES",
        "LANDING_BUCKET",
        "SSM_CONNECTION_PATH",
        "CONNECTION_NAME_PREFIX",
        "OUTPUT_FORMAT",
        "TABLES_TO_EXTRACT",
    ],
)

sc          = SparkContext()
glueContext = GlueContext(sc)
spark       = glueContext.spark_session
job         = Job(glueContext)
job.init(args["JOB_NAME"], args)

logger = glueContext.get_logger()

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
db_count              = int(args["DB_COUNT"])
database_names        = [n.strip() for n in args["DATABASE_NAMES"].split(",")]
landing_bucket        = args["LANDING_BUCKET"]
ssm_connection_path   = args["SSM_CONNECTION_PATH"]
connection_name_prefix = args["CONNECTION_NAME_PREFIX"]
output_format         = args["OUTPUT_FORMAT"].lower()
tables_arg            = args["TABLES_TO_EXTRACT"].strip()
tables_filter         = [t.strip() for t in tables_arg.split(",") if t.strip()] if tables_arg else []

extraction_date = str(date.today())   # YYYY-MM-DD partition

# ---------------------------------------------------------------------------
# Read connection parameters from SSM
# ---------------------------------------------------------------------------
ssm_client  = boto3.client("ssm")
ssm_response = ssm_client.get_parameter(
    Name=ssm_connection_path, WithDecryption=True
)
conn_params = json.loads(ssm_response["Parameter"]["Value"])
jdbc_host   = conn_params["host"]   # 10.32.127.4
jdbc_port   = conn_params["port"]   # 3306

logger.info(f"Connection params loaded — host={jdbc_host}, port={jdbc_port}")


# ---------------------------------------------------------------------------
# Helper: list tables in a MySQL schema using JDBC
# ---------------------------------------------------------------------------
def list_tables(jdbc_url: str, db_name: str, username: str, password: str) -> list[str]:
    df = (
        spark.read.format("jdbc")
        .option("url", jdbc_url)
        .option("query", f"SELECT table_name FROM information_schema.tables WHERE table_schema = '{db_name}' AND table_type = 'BASE TABLE'")
        .option("user", username)
        .option("password", password)
        .option("driver", "com.mysql.cj.jdbc.Driver")
        .load()
    )
    return [row["table_name"] for row in df.collect()]


# ---------------------------------------------------------------------------
# Helper: extract one table and write to S3
# ---------------------------------------------------------------------------
def extract_table(
    glue_context: GlueContext,
    connection_name: str,
    db_name: str,
    table_name: str,
    landing_bucket: str,
    output_format: str,
    extraction_date: str,
):
    s3_path = (
        f"s3://{landing_bucket}/{db_name}/{table_name}/"
        f"extraction_date={extraction_date}/"
    )

    try:
        dyf = glue_context.create_dynamic_frame.from_options(
            connection_type="mysql",
            connection_options={
                "connectionName": connection_name,
                "dbtable": table_name,
                "database": db_name,
            },
            transformation_ctx=f"{db_name}_{table_name}_extract",
        )

        if dyf.count() == 0:
            logger.info(f"[SKIP] {db_name}.{table_name} — 0 rows")
            return

        if output_format == "parquet":
            glue_context.write_dynamic_frame.from_options(
                frame=dyf,
                connection_type="s3",
                connection_options={"path": s3_path},
                format="glueparquet",
                format_options={"compression": "snappy"},
                transformation_ctx=f"{db_name}_{table_name}_write",
            )
        elif output_format == "csv":
            glue_context.write_dynamic_frame.from_options(
                frame=dyf,
                connection_type="s3",
                connection_options={"path": s3_path},
                format="csv",
                format_options={"separator": ",", "withHeader": "true"},
                transformation_ctx=f"{db_name}_{table_name}_write",
            )
        else:  # json
            glue_context.write_dynamic_frame.from_options(
                frame=dyf,
                connection_type="s3",
                connection_options={"path": s3_path},
                format="json",
                transformation_ctx=f"{db_name}_{table_name}_write",
            )

        logger.info(f"[OK] {db_name}.{table_name} → {s3_path}")

    except Exception as exc:
        # Log the error but continue processing remaining tables / databases
        logger.error(f"[ERROR] {db_name}.{table_name}: {exc}")


# ---------------------------------------------------------------------------
# Main extraction loop
# ---------------------------------------------------------------------------
errors = []

for idx in range(db_count):
    db_name         = database_names[idx]
    connection_name = f"{connection_name_prefix}{idx}"
    jdbc_url        = f"jdbc:mysql://{jdbc_host}:{jdbc_port}/{db_name}"

    logger.info(f"=== Processing DB {idx+1}/{db_count}: {db_name} ===")

    # Resolve which tables to extract
    if tables_filter:
        tables = tables_filter
    else:
        try:
            # Credentials are resolved by Glue through the connection object;
            # for the info_schema query we pass placeholders — override if needed.
            tables = list_tables(jdbc_url, db_name, "${USERNAME}", "${PASSWORD}")
        except Exception as e:
            logger.error(f"Could not list tables for {db_name}: {e}")
            errors.append((db_name, "*", str(e)))
            continue

    for table_name in tables:
        extract_table(
            glueContext,
            connection_name,
            db_name,
            table_name,
            landing_bucket,
            output_format,
            extraction_date,
        )

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
if errors:
    logger.error(f"Extraction completed with {len(errors)} error(s):")
    for db, tbl, msg in errors:
        logger.error(f"  {db}.{tbl} — {msg}")
else:
    logger.info("Extraction completed successfully with no errors.")

job.commit()
