"""
Databricks Declarative Pipelines (DLT) — Multi-OU AWS Billing Aggregator
==========================================================================

Architecture
------------
  Databricks Cluster (instance profile role)
      └─► AssumeRole ──► DatabricksBillingRole-<account_id>  (in each OU account)
              └─► AWS Cost Explorer API
                      └─► DLT Bronze / Silver / Gold tables

Pipeline configuration (databricks.yml or UI):
  - Set pipeline parameter:  billing_role_arns  (JSON string, see below)
  - Enable cluster instance profile with AssumeRole permissions

Example billing_role_arns parameter value:
{
  "production": {
    "111111111111": "arn:aws:iam::111111111111:role/DatabricksBillingRole-111111111111",
    "222222222222": "arn:aws:iam::222222222222:role/DatabricksBillingRole-222222222222"
  },
  "staging": {
    "333333333333": "arn:aws:iam::333333333333:role/DatabricksBillingRole-333333333333"
  }
}
"""

import json
import boto3
import datetime
from typing import Iterator
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField,
    StringType, DoubleType, DateType, TimestampType, MapType
)
import dlt

###############################################################################
# Pipeline Parameters
###############################################################################

# Injected via DLT pipeline configuration or spark.conf
def get_pipeline_param(key: str, default: str = "") -> str:
    try:
        return spark.conf.get(f"pipelines.{key}", default)
    except Exception:
        return default


BILLING_ROLE_ARNS_JSON: str = get_pipeline_param(
    "billing_role_arns",
    default="{}"
)

# Format: { "ou_name": { "account_id": "role_arn", ... }, ... }
BILLING_ROLE_ARNS: dict = json.loads(BILLING_ROLE_ARNS_JSON)

# Cost Explorer query window (default: current month)
TODAY = datetime.date.today()
QUERY_START: str = get_pipeline_param(
    "query_start",
    default=TODAY.replace(day=1).isoformat()          # first day of this month
)
QUERY_END: str = get_pipeline_param(
    "query_end",
    default=TODAY.isoformat()
)

EXTERNAL_ID: str = get_pipeline_param(
    "external_id",
    default="databricks-billing-aggregator"
)

TARGET_CATALOG: str  = get_pipeline_param("target_catalog",  default="billing")
TARGET_SCHEMA: str   = get_pipeline_param("target_schema",   default="aws_costs")

###############################################################################
# Schemas
###############################################################################

BRONZE_SCHEMA = StructType([
    StructField("ou",             StringType(),  False),
    StructField("account_id",     StringType(),  False),
    StructField("time_period_start", StringType(), False),
    StructField("time_period_end",   StringType(), False),
    StructField("service",        StringType(),  True),
    StructField("region",         StringType(),  True),
    StructField("usage_type",     StringType(),  True),
    StructField("linked_account", StringType(),  True),
    StructField("amount",         DoubleType(),  True),
    StructField("unit",           StringType(),  True),
    StructField("estimated",      StringType(),  True),
    StructField("ingested_at",    TimestampType(), False),
])

###############################################################################
# Helper: AssumeRole and return boto3 Cost Explorer client
###############################################################################

def get_ce_client(role_arn: str, account_id: str) -> "boto3.client":
    """
    Assume the billing role in the target account and return a CE client.
    The base credentials come from the Databricks cluster instance profile.
    """
    sts = boto3.client("sts", region_name="us-east-1")
    assumed = sts.assume_role(
        RoleArn=role_arn,
        RoleSessionName=f"databricks-billing-{account_id}",
        ExternalId=EXTERNAL_ID,
        DurationSeconds=3600,
    )
    creds = assumed["Credentials"]
    return boto3.client(
        "ce",
        region_name="us-east-1",
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


###############################################################################
# Helper: Paginate Cost Explorer GetCostAndUsage
###############################################################################

def fetch_cost_and_usage(
    ce_client,
    ou: str,
    account_id: str,
    start: str,
    end: str,
) -> Iterator[dict]:
    """
    Yield one flat record per (service, region, usageType, linkedAccount, timePeriod).
    Handles Cost Explorer pagination automatically.
    """
    ingested_at = datetime.datetime.utcnow()
    next_token = None

    while True:
        kwargs = dict(
            TimePeriod={"Start": start, "End": end},
            Granularity="DAILY",
            Metrics=["UnblendedCost"],
            GroupBy=[
                {"Type": "DIMENSION", "Key": "SERVICE"},
                {"Type": "DIMENSION", "Key": "REGION"},
                {"Type": "DIMENSION", "Key": "USAGE_TYPE"},
                {"Type": "DIMENSION", "Key": "LINKED_ACCOUNT"},
            ],
        )
        if next_token:
            kwargs["NextPageToken"] = next_token

        response = ce_client.get_cost_and_usage(**kwargs)

        for result in response.get("ResultsByTime", []):
            period_start = result["TimePeriod"]["Start"]
            period_end   = result["TimePeriod"]["End"]
            estimated    = str(result.get("Estimated", False))

            for group in result.get("Groups", []):
                keys      = group["Keys"]  # [service, region, usage_type, linked_account]
                metrics   = group["Metrics"]["UnblendedCost"]
                yield {
                    "ou":               ou,
                    "account_id":       account_id,
                    "time_period_start": period_start,
                    "time_period_end":   period_end,
                    "service":          keys[0] if len(keys) > 0 else None,
                    "region":           keys[1] if len(keys) > 1 else None,
                    "usage_type":       keys[2] if len(keys) > 2 else None,
                    "linked_account":   keys[3] if len(keys) > 3 else None,
                    "amount":           float(metrics["Amount"]),
                    "unit":             metrics["Unit"],
                    "estimated":        estimated,
                    "ingested_at":      ingested_at,
                }

        next_token = response.get("NextPageToken")
        if not next_token:
            break


###############################################################################
# Helper: Collect all OU records into a Python list (driver-side)
###############################################################################

def collect_all_billing_records() -> list[dict]:
    """
    Iterate over every OU / account, assume role, call Cost Explorer.
    Returns a flat list of raw records suitable for createDataFrame.
    """
    records = []
    for ou, accounts in BILLING_ROLE_ARNS.items():
        for account_id, role_arn in accounts.items():
            try:
                ce_client = get_ce_client(role_arn, account_id)
                for rec in fetch_cost_and_usage(ce_client, ou, account_id, QUERY_START, QUERY_END):
                    records.append(rec)
            except Exception as exc:
                # Log but continue — one failing account should not abort the pipeline
                print(f"[WARNING] Failed to fetch billing for {ou}/{account_id}: {exc}")
    return records


###############################################################################
# DLT Table: Bronze — raw cost records
###############################################################################

@dlt.table(
    name=f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_bronze",
    comment="Raw AWS Cost Explorer records from all OU accounts (append-only)",
    table_properties={
        "quality": "bronze",
        "pipelines.reset.allowed": "true",
    },
    partition_cols=["ou", "account_id"],
)
def aws_billing_bronze():
    records = collect_all_billing_records()

    if not records:
        # Return an empty DataFrame with the correct schema when no data
        return spark.createDataFrame([], schema=BRONZE_SCHEMA)

    df = spark.createDataFrame(records, schema=BRONZE_SCHEMA)
    return df


###############################################################################
# DLT Table: Silver — deduplicated, typed, enriched
###############################################################################

@dlt.table(
    name=f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_silver",
    comment="Cleaned and deduplicated AWS billing records",
    table_properties={"quality": "silver"},
    partition_cols=["ou", "account_id"],
)
@dlt.expect_or_drop("valid_amount",    "amount IS NOT NULL AND amount >= 0")
@dlt.expect_or_drop("valid_account",   "account_id IS NOT NULL")
@dlt.expect_or_drop("valid_period",    "time_period_start IS NOT NULL")
def aws_billing_silver():
    return (
        dlt.read(f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_bronze")
        .withColumn("time_period_start", F.to_date("time_period_start"))
        .withColumn("time_period_end",   F.to_date("time_period_end"))
        .withColumn("year",  F.year("time_period_start"))
        .withColumn("month", F.month("time_period_start"))
        # Drop duplicate rows that might arise from pipeline retries
        .dropDuplicates([
            "ou", "account_id", "time_period_start",
            "service", "region", "usage_type", "linked_account"
        ])
    )


###############################################################################
# DLT Table: Gold — aggregated daily cost by OU / account / service
###############################################################################

@dlt.table(
    name=f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_daily_by_service",
    comment="Daily AWS cost aggregated by OU, account, and service",
    table_properties={"quality": "gold"},
)
def aws_billing_daily_by_service():
    return (
        dlt.read(f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_silver")
        .groupBy("ou", "account_id", "linked_account", "time_period_start", "service", "year", "month")
        .agg(
            F.sum("amount").alias("total_cost_usd"),
            F.countDistinct("usage_type").alias("usage_type_count"),
        )
        .orderBy("time_period_start", "ou", "account_id", "service")
    )


###############################################################################
# DLT Table: Gold — monthly OU-level rollup
###############################################################################

@dlt.table(
    name=f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_monthly_by_ou",
    comment="Monthly total AWS cost rolled up at the OU level",
    table_properties={"quality": "gold"},
)
def aws_billing_monthly_by_ou():
    return (
        dlt.read(f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_silver")
        .groupBy("ou", "year", "month")
        .agg(
            F.sum("amount").alias("total_cost_usd"),
            F.countDistinct("account_id").alias("account_count"),
            F.countDistinct("service").alias("service_count"),
        )
        .orderBy("year", "month", "ou")
    )


###############################################################################
# DLT Table: Gold — top services by spend (last full month)
###############################################################################

@dlt.table(
    name=f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_top_services",
    comment="Top AWS services by spend across all OUs for the current query window",
    table_properties={"quality": "gold"},
)
def aws_billing_top_services():
    return (
        dlt.read(f"{TARGET_CATALOG}.{TARGET_SCHEMA}.aws_billing_silver")
        .groupBy("service")
        .agg(F.sum("amount").alias("total_cost_usd"))
        .orderBy(F.desc("total_cost_usd"))
    )
