"""
cariai-batch-extractor — Glue ETL script
==========================================
Architecture
------------
1. Reads shared JDBC config (host, port) from SSM Parameter Store.
2. Reads the dataset/table catalog from a second SSM parameter:
     /augusta-nexa-dev/cariai/batch/datasets
   The catalog has two sections:
     - "dim tables"  : static tables  — extract everything, no date filter.
     - "fact tables" : monthly tables — table name contains "(yyyy_mm)" which is
                       replaced with the current year/month at runtime.
                       Each fact table has a date_filter specifying which column
                       and format to use for incremental filtering.
3. For each of the 36 databases:
     a. Fetches per-DB credentials from Secrets Manager.
        Secret path: /<stack_id>/cariai/bdd/<connection_indicator>
        Secret JSON: {"user": "...", "password": "..."}
     b. Extracts each dim table  → s3://dev-landing/raw/<db_key>/dim/<output_path>/
     c. Extracts each fact table → s3://dev-landing/raw/<db_key>/fact/<output_path>/yyyy=YYYY/mm=MM/
        applying the date_filter to restrict rows to the current month.

Glue job arguments (injected by Terraform):
  --ssm_connection_path   SSM path for {"type","host","port"}
  --ssm_datasets_path     SSM path for the dataset catalog
  --s3_landing_bucket     Target bucket  (dev-landing)
  --db_secret_pairs       "db_key::secret_path,..."
  --aws_region            AWS region
  --JOB_NAME              Glue built-in
"""

import sys
import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

import boto3
from botocore.exceptions import ClientError

from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql import functions as F

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("cariai-extractor")

# ── Job arguments ─────────────────────────────────────────────────────────────
args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "ssm_connection_path",
        "ssm_datasets_path",
        "s3_landing_bucket",
        "db_secret_pairs",
        "aws_region",
    ],
)

JOB_NAME         = args["JOB_NAME"]
SSM_CONN_PATH    = args["ssm_connection_path"]
SSM_DATASETS_PATH = args["ssm_datasets_path"]
LANDING_BUCKET   = args["s3_landing_bucket"]
RAW_PAIRS        = args["db_secret_pairs"]
AWS_REGION       = args["aws_region"]

# ── Spark / Glue ──────────────────────────────────────────────────────────────
sc       = SparkContext()
glue_ctx = GlueContext(sc)
spark    = glue_ctx.spark_session
job      = Job(glue_ctx)
job.init(JOB_NAME, args)

# ── AWS clients ───────────────────────────────────────────────────────────────
ssm_client = boto3.client("ssm",            region_name=AWS_REGION)
sm_client  = boto3.client("secretsmanager", region_name=AWS_REGION)

# ── Runtime date (used for fact table name substitution and partitioning) ──────
NOW        = datetime.now(tz=timezone.utc)
YEAR_STR   = NOW.strftime("%Y")
MONTH_STR  = NOW.strftime("%m")
YYYY_MM    = f"{YEAR_STR}_{MONTH_STR}"   # e.g. "2026_05"  — matches (yyyy_mm) pattern


# ── Data structures ───────────────────────────────────────────────────────────
@dataclass
class DateFilter:
    column: str
    format: str   # e.g. "yyyy-MM-dd HH:mm:ss"  (Java/Spark format)


@dataclass
class TableDef:
    id:          str
    raw_name:    str             # may contain "(yyyy_mm)"
    output_path: str             # relative S3 path under dim/ or fact/
    table_type:  str             # "dim" | "fact"
    date_filter: Optional[DateFilter] = None

    @property
    def resolved_name(self) -> str:
        """Replace (yyyy_mm) placeholder with the current year_month."""
        return self.raw_name.replace("(yyyy_mm)", YYYY_MM)


@dataclass
class DbConfig:
    key:         str
    secret_path: str
    user:        Optional[str] = None
    password:    Optional[str] = None


@dataclass
class ExtractionResult:
    db_key:    str
    table_id:  str
    table_type: str
    success:   bool
    row_count: int = 0
    error:     str = ""


# ── SSM helpers ───────────────────────────────────────────────────────────────
def get_ssm(path: str, decrypt: bool = True) -> str:
    resp = ssm_client.get_parameter(Name=path, WithDecryption=decrypt)
    return resp["Parameter"]["Value"]


def load_connection_config() -> dict:
    config = json.loads(get_ssm(SSM_CONN_PATH))
    logger.info("Connection config: host=%s port=%s", config["host"], config["port"])
    return config


def load_dataset_catalog() -> tuple[list[TableDef], list[TableDef]]:
    """
    Parse the SSM dataset catalog into two lists: dim_tables, fact_tables.

    Expected SSM JSON structure:
    {
      "dim tables": [
        {
          "id": "bots",
          "name": "Bots",
          "description": "...",
          "output": {"path": "bots"}
        }
      ],
      "fact tables": [
        {
          "id": "clientes",
          "name": "ClientesV2_(yyyy_mm)",
          "description": "...",
          "output": {"path": "clientes"},
          "date_filter": {"column": "fecha_creacion", "format": "yyyy-MM-dd HH:mm:ss"}
        }
      ]
    }
    """
    raw     = json.loads(get_ssm(SSM_DATASETS_PATH, decrypt=False))

    dim_tables = []
    for entry in raw.get("dim tables", []):
        dim_tables.append(TableDef(
            id          = entry["id"],
            raw_name    = entry["name"],
            output_path = entry["output"]["path"],
            table_type  = "dim",
        ))

    fact_tables = []
    for entry in raw.get("fact tables", []):
        df_cfg = entry.get("date_filter")
        fact_tables.append(TableDef(
            id          = entry["id"],
            raw_name    = entry["name"],
            output_path = entry["output"]["path"],
            table_type  = "fact",
            date_filter = DateFilter(
                column = df_cfg["column"],
                format = df_cfg["format"],
            ) if df_cfg else None,
        ))

    logger.info(
        "Dataset catalog: %d dim tables, %d fact tables",
        len(dim_tables), len(fact_tables),
    )
    for t in dim_tables:
        logger.info("  [dim]  %s → resolved name: %s", t.id, t.resolved_name)
    for t in fact_tables:
        logger.info("  [fact] %s → resolved name: %s (filter: %s)",
                    t.id, t.resolved_name,
                    f"{t.date_filter.column}" if t.date_filter else "none")
    return dim_tables, fact_tables


# ── Secrets Manager helper ────────────────────────────────────────────────────
def fetch_db_credentials(db: DbConfig) -> None:
    """
    Fetch {"user": "...", "password": "..."} from Secrets Manager.
    Populates db.user and db.password in-place.
    """
    try:
        resp   = sm_client.get_secret_value(SecretId=db.secret_path)
        secret = json.loads(resp["SecretString"])
        db.user     = secret["user"]
        db.password = secret["password"]
    except ClientError as exc:
        raise RuntimeError(
            f"[{db.key}] Cannot fetch secret '{db.secret_path}': "
            f"[{exc.response['Error']['Code']}] {exc}"
        ) from exc
    except KeyError as exc:
        raise RuntimeError(
            f"[{db.key}] Secret '{db.secret_path}' missing key {exc}. "
            f"Expected: {{\"user\": \"...\", \"password\": \"...\"}}"
        ) from exc


def clear_credentials(db: DbConfig) -> None:
    """Remove credentials from memory after the DB is done."""
    db.user     = None
    db.password = None


# ── Argument parser ───────────────────────────────────────────────────────────
def parse_db_secret_pairs(raw: str) -> list[DbConfig]:
    """'db_key::secret_path,...' → list of DbConfig."""
    configs = []
    for token in raw.split(","):
        token = token.strip()
        if not token:
            continue
        parts = token.split("::", maxsplit=1)
        if len(parts) != 2:
            logger.warning("Skipping malformed token: '%s'", token)
            continue
        configs.append(DbConfig(key=parts[0].strip(), secret_path=parts[1].strip()))
    return configs


# ── JDBC read helpers ─────────────────────────────────────────────────────────
def jdbc_options(jdbc_url: str, db: DbConfig) -> dict:
    return {
        "url":            jdbc_url,
        "user":           db.user,
        "password":       db.password,
        "driver":         "com.mysql.cj.jdbc.Driver",
        "fetchsize":      "10000",
        "numPartitions":  "4",
    }


def read_dim_table(jdbc_url: str, db: DbConfig, table: TableDef):
    """Read a dim (static) table — no date filtering."""
    opts = jdbc_options(jdbc_url, db)
    opts["dbtable"] = table.resolved_name
    return (
        spark.read
        .format("jdbc")
        .options(**opts)
        .load()
    )


def read_fact_table(jdbc_url: str, db: DbConfig, table: TableDef):
    """
    Read a fact table filtered to the current month using the date_filter config.

    The filter is pushed down to MySQL via a JDBC sub-query, so only the current
    month's rows are transferred over the network.

    Date format translation (Spark → MySQL):
      yyyy-MM-dd HH:mm:ss  →  '%Y-%m-%d %H:%i:%s'
    We build the MySQL WHERE clause directly because Spark's pushdown for
    timestamp ranges is not always reliable across JDBC drivers.
    """
    resolved = table.resolved_name

    if table.date_filter:
        col     = table.date_filter.column
        # Build month boundaries in MySQL-compatible format
        # First day of current month  /  first day of next month
        month_start = f"{YEAR_STR}-{MONTH_STR}-01 00:00:00"
        # Calculate next month safely
        if NOW.month == 12:
            next_year, next_month = NOW.year + 1, 1
        else:
            next_year, next_month = NOW.year, NOW.month + 1
        month_end = f"{next_year}-{next_month:02d}-01 00:00:00"

        pushdown_query = (
            f"(SELECT * FROM `{resolved}` "
            f"WHERE `{col}` >= '{month_start}' "
            f"  AND `{col}` <  '{month_end}') AS t"
        )
        logger.info(
            "    [fact] pushdown filter on '%s': %s >= '%s' AND < '%s'",
            resolved, col, month_start, month_end,
        )
    else:
        # No date_filter defined — read the full fact table
        logger.warning(
            "    [fact] '%s' has no date_filter — reading full table", resolved
        )
        pushdown_query = f"(SELECT * FROM `{resolved}`) AS t"

    opts = jdbc_options(jdbc_url, db)
    opts["dbtable"] = pushdown_query
    return (
        spark.read
        .format("jdbc")
        .options(**opts)
        .load()
    )


# ── S3 write helpers ──────────────────────────────────────────────────────────
def s3_path_dim(db_key: str, table: TableDef) -> str:
    return f"s3://{LANDING_BUCKET}/raw/{db_key}/dim/{table.output_path}/"


def s3_path_fact(db_key: str, table: TableDef) -> str:
    # Partition by year and month so downstream queries can prune cheaply
    return (
        f"s3://{LANDING_BUCKET}/raw/{db_key}/fact/{table.output_path}/"
        f"yyyy={YEAR_STR}/mm={MONTH_STR}/"
    )


def write_parquet(df, s3_path: str) -> int:
    count = df.count()
    df.write.mode("overwrite").parquet(s3_path)
    return count


# ── Per-database extraction ───────────────────────────────────────────────────
def extract_database(
    db: DbConfig,
    jdbc_base_url: str,
    dim_tables: list[TableDef],
    fact_tables: list[TableDef],
) -> list[ExtractionResult]:
    """
    Full extraction for one database.
    Credentials are fetched at the start and cleared at the end.
    """
    results = []
    jdbc_url = f"{jdbc_base_url}{db.key}"

    fetch_db_credentials(db)
    logger.info("  Credentials loaded for '%s'", db.key)

    try:
        # ── Dim tables ───────────────────────────────────────────────────────
        for table in dim_tables:
            s3_path = s3_path_dim(db.key, table)
            try:
                df    = read_dim_table(jdbc_url, db, table)
                rows  = write_parquet(df, s3_path)
                logger.info("    ✓ [dim]  %s → %s (%d rows)", table.resolved_name, s3_path, rows)
                results.append(ExtractionResult(
                    db_key=db.key, table_id=table.id, table_type="dim",
                    success=True, row_count=rows,
                ))
            except Exception as exc:     # noqa: BLE001
                logger.error("    ✗ [dim]  %s failed: %s", table.resolved_name, exc)
                results.append(ExtractionResult(
                    db_key=db.key, table_id=table.id, table_type="dim",
                    success=False, error=str(exc),
                ))

        # ── Fact tables ──────────────────────────────────────────────────────
        for table in fact_tables:
            s3_path = s3_path_fact(db.key, table)
            try:
                df    = read_fact_table(jdbc_url, db, table)
                rows  = write_parquet(df, s3_path)
                logger.info("    ✓ [fact] %s → %s (%d rows)", table.resolved_name, s3_path, rows)
                results.append(ExtractionResult(
                    db_key=db.key, table_id=table.id, table_type="fact",
                    success=True, row_count=rows,
                ))
            except Exception as exc:     # noqa: BLE001
                logger.error("    ✗ [fact] %s failed: %s", table.resolved_name, exc)
                results.append(ExtractionResult(
                    db_key=db.key, table_id=table.id, table_type="fact",
                    success=False, error=str(exc),
                ))

    finally:
        # Always clear credentials regardless of extraction outcome
        clear_credentials(db)

    return results


# ── Main ──────────────────────────────────────────────────────────────────────
logger.info("=" * 70)
logger.info("cariai-batch-extractor  |  run date: %s-%s", YEAR_STR, MONTH_STR)
logger.info("=" * 70)

conn_cfg       = load_connection_config()
jdbc_base_url  = f"jdbc:mysql://{conn_cfg['host']}:{conn_cfg['port']}/"

dim_tables, fact_tables = load_dataset_catalog()

db_configs  = parse_db_secret_pairs(RAW_PAIRS)
logger.info("Databases to process: %d", len(db_configs))

all_results: list[ExtractionResult] = []
failed_dbs: list[str] = []

for db in db_configs:
    logger.info("─" * 60)
    logger.info("► Database: %s  (secret: %s)", db.key, db.secret_path)
    try:
        results = extract_database(db, jdbc_base_url, dim_tables, fact_tables)
        all_results.extend(results)
    except Exception as exc:     # noqa: BLE001
        logger.error("  Database '%s' aborted: %s", db.key, exc)
        failed_dbs.append(db.key)
        all_results.append(ExtractionResult(
            db_key=db.key, table_id="__all__", table_type="unknown",
            success=False, error=str(exc),
        ))

# ── Final summary ─────────────────────────────────────────────────────────────
logger.info("=" * 70)
logger.info("EXTRACTION SUMMARY  |  %s-%s", YEAR_STR, MONTH_STR)
logger.info("=" * 70)

succeeded = [r for r in all_results if r.success]
failed    = [r for r in all_results if not r.success]

logger.info("Databases processed : %d", len(db_configs))
logger.info("Tables succeeded    : %d  (%d rows total)",
            len(succeeded), sum(r.row_count for r in succeeded))
logger.info("Tables failed       : %d", len(failed))

if failed:
    logger.error("Failed extractions:")
    for r in failed:
        logger.error("  ✗ [%s] %s/%s — %s", r.table_type, r.db_key, r.table_id, r.error)

if failed_dbs:
    logger.error("Databases that failed entirely: %s", failed_dbs)

job.commit()
