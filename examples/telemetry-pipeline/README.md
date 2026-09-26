# Telemetry pipeline

A complete batch pipeline, the kind that runs on AWS as **Airflow → S3 → Glue → Iceberg → Glue Data Catalog**, written as ordinary code:

| File | What it is |
|---|---|
| `dags/telemetry_gold.py` | Airflow DAG: lands raw device readings in a bucket, runs the Spark job, harvests the catalog |
| `spark/gold_etl.py` | PySpark job: dedupe, glitch cleaning, rolling z-score anomalies, sessionisation, daily and per-session **gold** tables in Parquet |

Give the Sandbox Factory this folder (or its Git URL) and it builds what the code needs on OCI:

| Code needs | OCI |
|---|---|
| a bucket for raw/ and gold/ | Object Storage bucket `sbx-<id>-data` |
| a Spark job | Data Flow application `sbx-<id>-gold-etl` with `spark/gold_etl.py` |
| a catalog | Data Catalog `sbx-<id>-catalog` |
| a database (the DAG loads the gold tables into it) | Autonomous Database 23ai, tables `TELEMETRY_DAILY`, `TELEMETRY_SESSIONS`, Select AI + REST on |
| Airflow | Airflow in a container instance, this DAG loaded, admin login on the card |

The DAG runs once as soon as Airflow starts. Open Airflow from the sandbox card to watch the three tasks, then open the bucket to see `gold/telemetry_daily/` and `gold/telemetry_sessions/`, and the catalog to browse the harvested tables.

Nothing here is factory-specific: the DAG reads the bucket, job and catalog names from environment variables the sandbox injects, and authenticates as the container it runs in.
