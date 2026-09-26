"""Telemetry: raw readings -> gold tables. Runs on OCI Data Flow (managed Spark).

The AWS shape this replaces is Glue reading S3 and writing Iceberg. Here the
job reads the raw CSV files from an Object Storage bucket and writes two gold
tables back to the same bucket, in Parquet, partitioned by day:

    gold/telemetry_daily/     one row per device per day
    gold/telemetry_sessions/  one row per device session
    gold_oracle/...           the same, flat, for loading into the database

Nothing in the transformation is Spark-vendor specific; it runs unchanged on
Glue, EMR or Data Flow. Only the URIs differ (oci:// instead of s3://).

Arguments (all optional, from the Data Flow application):
    --bucket <name>   the sandbox data bucket (default: $DATA_BUCKET)
    --namespace <ns>  Object Storage namespace (default: $OCI_NAMESPACE)
"""
import argparse
import os
import sys

from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql import types as T


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--bucket", default=os.environ.get("DATA_BUCKET", ""))
    p.add_argument("--namespace", default=os.environ.get("OCI_NAMESPACE", ""))
    return p.parse_args()


def main():
    a = parse_args()
    if not (a.bucket and a.namespace):
        sys.exit("bucket and namespace are required (--bucket/--namespace or DATA_BUCKET/OCI_NAMESPACE)")
    base = f"oci://{a.bucket}@{a.namespace}"
    spark = SparkSession.builder.appName("telemetry-gold").getOrCreate()

    schema = T.StructType([
        T.StructField("device_id", T.StringType()),
        T.StructField("site", T.StringType()),
        T.StructField("ts", T.StringType()),
        T.StructField("temperature_c", T.DoubleType()),
        T.StructField("humidity_pct", T.DoubleType()),
        T.StructField("battery_pct", T.DoubleType()),
        T.StructField("event", T.StringType()),
    ])

    # ---- bronze: read everything the DAG landed under raw/ -----------------
    raw = spark.read.option("header", True).schema(schema).csv(f"{base}/raw/")
    raw = raw.withColumn("ts", F.to_timestamp("ts")).where(F.col("ts").isNotNull())

    # ---- silver: clean -------------------------------------------------------
    # 1. Devices retransmit: keep the last reading per (device, ts).
    latest = Window.partitionBy("device_id", "ts").orderBy(F.col("battery_pct").desc_nulls_last())
    silver = (raw.withColumn("rn", F.row_number().over(latest)).where("rn = 1").drop("rn")
              # 2. Sensor glitches read as physically impossible values.
              .withColumn("temperature_c", F.when((F.col("temperature_c") < -40) | (F.col("temperature_c") > 85), None)
                          .otherwise(F.col("temperature_c")))
              .withColumn("day", F.to_date("ts")))

    # 3. Rolling z-score per device over the previous 20 readings: flag anomalies
    #    the way an ops team would, relative to that device's own recent behaviour.
    trailing = Window.partitionBy("device_id").orderBy("ts").rowsBetween(-20, -1)
    silver = (silver
              .withColumn("t_mean", F.avg("temperature_c").over(trailing))
              .withColumn("t_std", F.stddev("temperature_c").over(trailing))
              .withColumn("t_z", F.when(F.col("t_std") > 0, (F.col("temperature_c") - F.col("t_mean")) / F.col("t_std")))
              .withColumn("is_anomaly", (F.abs(F.col("t_z")) > 3) | (F.col("event") == "fault")))

    # 4. Sessionise: a gap of more than 5 minutes between readings starts a new session.
    by_dev = Window.partitionBy("device_id").orderBy("ts")
    silver = (silver
              .withColumn("prev_ts", F.lag("ts").over(by_dev))
              .withColumn("gap_s", F.unix_timestamp("ts") - F.unix_timestamp("prev_ts"))
              .withColumn("new_session", F.when(F.col("prev_ts").isNull() | (F.col("gap_s") > 300), 1).otherwise(0))
              .withColumn("session_no", F.sum("new_session").over(by_dev))
              .withColumn("session_id", F.concat_ws("-", "device_id", F.col("session_no").cast("string"))))

    # ---- gold 1: one row per device per day --------------------------------
    daily = (silver.groupBy("day", "site", "device_id").agg(
        F.count("*").alias("readings"),
        F.round(F.avg("temperature_c"), 2).alias("temp_avg_c"),
        F.round(F.min("temperature_c"), 2).alias("temp_min_c"),
        F.round(F.max("temperature_c"), 2).alias("temp_max_c"),
        F.round(F.expr("percentile_approx(temperature_c, 0.95)"), 2).alias("temp_p95_c"),
        F.round(F.avg("humidity_pct"), 1).alias("humidity_avg_pct"),
        F.round(F.min("battery_pct"), 1).alias("battery_min_pct"),
        F.sum(F.col("is_anomaly").cast("int")).alias("anomalies"),
        F.countDistinct("session_id").alias("sessions"),
        F.sum(F.when(F.col("event") == "fault", 1).otherwise(0)).alias("faults"))
        .withColumn("health", F.when(F.col("faults") > 0, "faulty")
                    .when(F.col("anomalies") > 3, "watch")
                    .when(F.col("battery_min_pct") < 15, "low battery")
                    .otherwise("ok")))

    # ---- gold 2: one row per session -----------------------------------------
    sessions = (silver.groupBy("day", "device_id", "session_id").agg(
        F.min("ts").alias("started_at"),
        F.max("ts").alias("ended_at"),
        F.count("*").alias("readings"),
        F.round(F.avg("temperature_c"), 2).alias("temp_avg_c"),
        F.sum(F.col("is_anomaly").cast("int")).alias("anomalies"))
        .withColumn("duration_min", F.round((F.unix_timestamp("ended_at") - F.unix_timestamp("started_at")) / 60.0, 1)))

    daily.write.mode("overwrite").partitionBy("day").parquet(f"{base}/gold/telemetry_daily/")
    sessions.write.mode("overwrite").partitionBy("day").parquet(f"{base}/gold/telemetry_sessions/")
    # Flat copies (day kept as a column, one folder of files) for the database
    # load: DBMS_CLOUD.COPY_DATA reads a folder of Parquet files by name.
    daily.coalesce(1).write.mode("overwrite").parquet(f"{base}/gold_oracle/telemetry_daily/")
    sessions.coalesce(1).write.mode("overwrite").parquet(f"{base}/gold_oracle/telemetry_sessions/")

    n_daily, n_sess = daily.count(), sessions.count()
    print(f"gold written: telemetry_daily={n_daily} rows, telemetry_sessions={n_sess} rows -> {base}/gold/")
    spark.stop()


if __name__ == "__main__":
    main()
