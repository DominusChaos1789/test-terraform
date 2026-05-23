"""
Glue Job Name : cariai-batch-extractor
Purpose       : Test Aurora MySQL connectivity and extract conversaciones_2026_05
                for a given date range, landing results as Parquet in S3.

Connection parameters (hardcoded for test – move to Secrets Manager for prod)
  Host     : 10.32.127.4
  Port     : 3306
  Database : nexabancobogota
  User     : test_user
  Password : test_pass

VPC / Security Group : sg-05698cc6f2e6d512g
Target S3            : s3://augusta-nexa-dev-landing/cariai/batch/
"""

import sys
import logging
from datetime import datetime

# ── AWS Glue / PySpark imports ────────────────────────────────────────────────
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql import functions as F

# ── Logging setup ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# ── Job initialisation ────────────────────────────────────────────────────────
args = getResolvedOptions(sys.argv, ["JOB_NAME"])

sc          = SparkContext()
glueContext = GlueContext(sc)
spark       = glueContext.spark_session
job         = Job(glueContext)
job.init(args["JOB_NAME"], args)

# ── Connection config ─────────────────────────────────────────────────────────
MYSQL_HOST     = "10.32.127.4"
MYSQL_PORT     = 3306
MYSQL_DATABASE = "nexabancobogota"
MYSQL_USER     = "test_user"
MYSQL_PASSWORD = "test_pass"          # 🔒 Move to AWS Secrets Manager for prod
MYSQL_TABLE    = "conversaciones_2026_05"

DATE_FROM = "2026-05-23 00:00:00"
DATE_TO   = "2026-05-23 23:59:59"

S3_OUTPUT = "s3://augusta-nexa-dev-landing/cariai/batch/"

JDBC_URL = (
    f"jdbc:mysql://{MYSQL_HOST}:{MYSQL_PORT}/{MYSQL_DATABASE}"
    "?useSSL=false"
    "&allowPublicKeyRetrieval=true"
    "&serverTimezone=America/Bogota"
)

# ── STEP 1 – Connectivity test via a lightweight query ────────────────────────
logger.info("=" * 60)
logger.info("STEP 1 – Testing Aurora MySQL connection …")
logger.info("  Host      : %s", MYSQL_HOST)
logger.info("  Port      : %s", MYSQL_PORT)
logger.info("  Database  : %s", MYSQL_DATABASE)
logger.info("  User      : %s", MYSQL_USER)
logger.info("  JDBC URL  : %s", JDBC_URL)
logger.info("=" * 60)

try:
    ping_query = "(SELECT 1 AS ping) AS connectivity_test"

    ping_df = (
        spark.read.format("jdbc")
        .option("url",      JDBC_URL)
        .option("dbtable",  ping_query)
        .option("user",     MYSQL_USER)
        .option("password", MYSQL_PASSWORD)
        .option("driver",   "com.mysql.cj.jdbc.Driver")
        .load()
    )

    ping_df.show()
    logger.info("✅  Connection successful – Aurora MySQL is reachable.")

except Exception as e:
    logger.error("❌  Connection FAILED: %s", str(e))
    raise RuntimeError(f"Cannot reach Aurora MySQL at {MYSQL_HOST}:{MYSQL_PORT}") from e

# ── STEP 2 – Row-count validation before full extract ─────────────────────────
logger.info("=" * 60)
logger.info("STEP 2 – Row count for date range %s → %s", DATE_FROM, DATE_TO)
logger.info("=" * 60)

count_query = f"""
    (
        SELECT COUNT(*) AS total_rows
        FROM   {MYSQL_TABLE}
        WHERE  fecha_creacion BETWEEN '{DATE_FROM}' AND '{DATE_TO}'
    ) AS row_count_check
"""

try:
    count_df = (
        spark.read.format("jdbc")
        .option("url",      JDBC_URL)
        .option("dbtable",  count_query)
        .option("user",     MYSQL_USER)
        .option("password", MYSQL_PASSWORD)
        .option("driver",   "com.mysql.cj.jdbc.Driver")
        .load()
    )

    total_rows = count_df.collect()[0]["total_rows"]
    logger.info("📊  Rows found in range: %s", total_rows)

    if total_rows == 0:
        logger.warning("⚠️  No rows found for the specified date range. Exiting gracefully.")
        job.commit()
        sys.exit(0)

except Exception as e:
    logger.error("❌  Row count query failed: %s", str(e))
    raise

# ── STEP 3 – Full data extract ────────────────────────────────────────────────
logger.info("=" * 60)
logger.info("STEP 3 – Extracting data from %s …", MYSQL_TABLE)
logger.info("=" * 60)

extract_query = f"""
    (
        SELECT *
        FROM   {MYSQL_TABLE}
        WHERE  fecha_creacion BETWEEN '{DATE_FROM}' AND '{DATE_TO}'
    ) AS data_extract
"""

try:
    df = (
        spark.read.format("jdbc")
        .option("url",              JDBC_URL)
        .option("dbtable",          extract_query)
        .option("user",             MYSQL_USER)
        .option("password",         MYSQL_PASSWORD)
        .option("driver",           "com.mysql.cj.jdbc.Driver")
        .option("fetchsize",        "1000")          # rows per JDBC fetch batch
        .option("numPartitions",    "4")             # parallel JDBC readers
        .load()
    )

    logger.info("Schema:")
    df.printSchema()
    logger.info("Sample rows (top 5):")
    df.show(5, truncate=False)

    actual_count = df.count()
    logger.info("✅  Rows loaded into Spark DataFrame: %s", actual_count)

except Exception as e:
    logger.error("❌  Data extraction failed: %s", str(e))
    raise

# ── STEP 4 – Add audit columns & write to S3 as Parquet ───────────────────────
logger.info("=" * 60)
logger.info("STEP 4 – Writing Parquet to %s", S3_OUTPUT)
logger.info("=" * 60)

# Partition path: year=2026/month=05/day=23/
partition_date = datetime.strptime(DATE_FROM, "%Y-%m-%d %H:%M:%S")
s3_partition   = (
    f"{S3_OUTPUT}"
    f"year={partition_date.year}/"
    f"month={partition_date.month:02d}/"
    f"day={partition_date.day:02d}/"
)

df_enriched = (
    df
    .withColumn("_etl_job",        F.lit(args["JOB_NAME"]))
    .withColumn("_etl_source",     F.lit(f"{MYSQL_DATABASE}.{MYSQL_TABLE}"))
    .withColumn("_etl_load_ts",    F.current_timestamp())
    .withColumn("_etl_date_from",  F.lit(DATE_FROM))
    .withColumn("_etl_date_to",    F.lit(DATE_TO))
)

try:
    (
        df_enriched.write
        .mode("overwrite")
        .option("compression", "snappy")
        .parquet(s3_partition)
    )
    logger.info("✅  Data written successfully to: %s", s3_partition)

except Exception as e:
    logger.error("❌  S3 write failed: %s", str(e))
    raise

# ── Done ──────────────────────────────────────────────────────────────────────
logger.info("=" * 60)
logger.info("🎉  cariai-batch-extractor completed successfully.")
logger.info("    Rows processed : %s", actual_count)
logger.info("    S3 output      : %s", s3_partition)
logger.info("=" * 60)

job.commit()
