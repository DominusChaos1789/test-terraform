"""
cariai_whatsapp_extractor.py
────────────────────────────
AWS Glue ETL script – CarIAI WhatsApp schema extractor.

For each of the 36 Aurora MySQL schemas (supplied via the --schemas argument)
the script:
  1. Opens a direct pymysql connection using the schema-specific credentials.
  2. Discovers every table in the schema.
  3. Reads all rows from each table.
  4. Writes a gzip-compressed NDJSON file to:
       s3://<landing_bucket>/<landing_prefix><schema_name>/<table_name>/<run_date>.json.gz

Run date is taken from the Glue job run timestamp so each execution produces
a new, non-overlapping partition.

Arguments (passed by Glue via --default_arguments):
  --aurora_host     Aurora MySQL cluster endpoint
  --aurora_port     Port (default 3306)
  --schemas         JSON list: [{schema_name, username, password}, ...]
  --landing_bucket  S3 bucket name for output (dev-landing)
  --landing_prefix  S3 prefix (cariai/)
"""

import sys
import json
import gzip
import datetime
import logging

import boto3
import pymysql
import pymysql.cursors

from awsglue.utils import getResolvedOptions

# ─── Logging ────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s – %(message)s",
)
logger = logging.getLogger("cariai-extractor")

# ─── Job arguments ──────────────────────────────────────────────────────────
REQUIRED_ARGS = [
    "aurora_host",
    "aurora_port",
    "schemas",
    "landing_bucket",
    "landing_prefix",
]

args = getResolvedOptions(sys.argv, REQUIRED_ARGS)

AURORA_HOST     = args["aurora_host"]
AURORA_PORT     = int(args["aurora_port"])
LANDING_BUCKET  = args["landing_bucket"]
LANDING_PREFIX  = args["landing_prefix"].rstrip("/") + "/"
SCHEMAS: list   = json.loads(args["schemas"])

# ─── S3 client ──────────────────────────────────────────────────────────────
s3 = boto3.client("s3")

# ─── Helpers ────────────────────────────────────────────────────────────────

def _get_connection(host: str, port: int, user: str, password: str, schema: str):
    """Return an open pymysql connection to the given schema."""
    return pymysql.connect(
        host=host,
        port=port,
        user=user,
        password=password,
        database=schema,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=30,
        read_timeout=300,
        autocommit=True,
    )


def _list_tables(conn) -> list[str]:
    """Return all table names for the current schema."""
    with conn.cursor() as cur:
        cur.execute("SHOW TABLES")
        rows = cur.fetchall()
    # SHOW TABLES returns dicts like {"Tables_in_<schema>": "table_name"}
    return [list(row.values())[0] for row in rows]


def _fetch_table(conn, table: str) -> list[dict]:
    """Fetch all rows from a table as a list of dicts."""
    with conn.cursor() as cur:
        cur.execute(f"SELECT * FROM `{table}`")  # nosec – table names come from SHOW TABLES
        return cur.fetchall()


def _serialize_row(row: dict) -> bytes:
    """Serialize a dict row to a JSON bytes line, handling non-serialisable types."""

    def _default(obj):
        if isinstance(obj, (datetime.date, datetime.datetime)):
            return obj.isoformat()
        if isinstance(obj, bytes):
            return obj.decode("utf-8", errors="replace")
        return str(obj)

    return (json.dumps(row, default=_default, ensure_ascii=False) + "\n").encode("utf-8")


def _upload_ndjson_gz(rows: list[dict], bucket: str, key: str) -> None:
    """Gzip-compress and upload a list of row dicts as NDJSON to S3."""
    compressed = gzip.compress(b"".join(_serialize_row(r) for r in rows))
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=compressed,
        ContentEncoding="gzip",
        ContentType="application/json",
    )
    logger.info("Uploaded s3://%s/%s  (%d bytes, %d rows)", bucket, key, len(compressed), len(rows))


def _build_s3_key(prefix: str, schema_name: str, table_name: str, run_date: str) -> str:
    """
    Partition layout:
      <prefix><schema_name>/<table_name>/run_date=<YYYY-MM-DD>/<table_name>.json.gz
    This makes the output Athena/Glue-crawlable immediately.
    """
    return (
        f"{prefix}{schema_name}/{table_name}/"
        f"run_date={run_date}/{table_name}.json.gz"
    )

# ─── Main extraction loop ────────────────────────────────────────────────────

def main():
    run_date = datetime.datetime.utcnow().strftime("%Y-%m-%d")
    logger.info("CarIAI WhatsApp extractor started – run_date=%s", run_date)
    logger.info("Target: s3://%s/%s", LANDING_BUCKET, LANDING_PREFIX)
    logger.info("Schemas to process: %d", len(SCHEMAS))

    total_tables  = 0
    total_rows    = 0
    failed_tables = []

    for schema_cfg in SCHEMAS:
        schema_name = schema_cfg["schema_name"]
        username    = schema_cfg["username"]
        password    = schema_cfg["password"]

        logger.info("── Processing schema: %s", schema_name)

        try:
            conn = _get_connection(
                host=AURORA_HOST,
                port=AURORA_PORT,
                user=username,
                password=password,
                schema=schema_name,
            )
        except Exception as exc:
            logger.error("Could not connect to schema %s: %s", schema_name, exc)
            failed_tables.append(f"{schema_name}.__connection__")
            continue

        try:
            tables = _list_tables(conn)
            logger.info("  Found %d tables in %s", len(tables), schema_name)

            for table in tables:
                try:
                    rows = _fetch_table(conn, table)
                    if not rows:
                        logger.info("  [SKIP] %s.%s – empty table", schema_name, table)
                        continue

                    s3_key = _build_s3_key(LANDING_PREFIX, schema_name, table, run_date)
                    _upload_ndjson_gz(rows, LANDING_BUCKET, s3_key)

                    total_tables += 1
                    total_rows   += len(rows)

                except Exception as exc:
                    logger.error("  [ERROR] %s.%s: %s", schema_name, table, exc)
                    failed_tables.append(f"{schema_name}.{table}")

        finally:
            conn.close()

    # ── Summary ──────────────────────────────────────────────────────────────
    logger.info("═" * 60)
    logger.info("Extraction complete.")
    logger.info("  Tables written : %d", total_tables)
    logger.info("  Total rows     : %d", total_rows)
    logger.info("  Failed items   : %d", len(failed_tables))

    if failed_tables:
        logger.warning("Failed tables/connections:")
        for item in failed_tables:
            logger.warning("  • %s", item)
        # Raise so Glue marks the run as failed and triggers retries/alerts
        raise RuntimeError(
            f"Extraction finished with {len(failed_tables)} failure(s). "
            "Review the logs for details."
        )


if __name__ == "__main__":
    main()
