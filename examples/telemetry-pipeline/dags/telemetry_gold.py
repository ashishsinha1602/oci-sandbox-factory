"""Telemetry pipeline: land raw readings, build the gold tables with Spark,
register them in the catalog. The AWS shape this replaces:

    Airflow (MWAA)  ->  S3 (raw)  ->  Glue job  ->  Iceberg/Athena gold table  ->  Glue Data Catalog

On OCI, task for task:

    Airflow (container instance)  ->  Object Storage (raw/)  ->  Data Flow run of spark/gold_etl.py
                                  ->  Object Storage (gold/)  ->  Data Catalog harvest
                                  ->  Autonomous Database tables TELEMETRY_DAILY / TELEMETRY_SESSIONS
                                      (Select AI and REST are already on, so you can ask them questions)

The DAG authenticates as the container it runs in (resource principal): no
keys anywhere. Everything it needs comes from the environment the sandbox
injects:

    SANDBOX_ID, SANDBOX_COMPARTMENT_OCID      always
    DATA_BUCKET, OCI_NAMESPACE                the sandbox data bucket
    DATAFLOW_APP_NAME                         the Spark job (default sbx-<id>-gold-etl)
    DATA_CATALOG_NAME                         the catalog (default sbx-<id>-catalog)
    ADB_CONNECT_STRING, ADB_ADMIN_PASSWORD    the sandbox database, when it has one:
                                              the gold tables are loaded into it as well

It runs once when the scheduler loads it (schedule "@once", unpaused), and
can be re-run from the Airflow UI any time. Set PIPELINE_SCHEDULE to a cron
expression (e.g. "*/10 * * * *") or an Airflow preset ("@hourly") to keep it
running on a schedule; every run lands fresh readings, rebuilds the gold tables
and reloads the database.
"""
from __future__ import annotations

import csv
import io
import math
import os
import random
import time
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator

SANDBOX = os.environ.get("SANDBOX_ID", "sandbox")
COMPARTMENT = os.environ.get("SANDBOX_COMPARTMENT_OCID", "")
BUCKET = os.environ.get("DATA_BUCKET", f"sbx-{SANDBOX}-data")
NAMESPACE = os.environ.get("OCI_NAMESPACE", "")
DATAFLOW_APP = os.environ.get("DATAFLOW_APP_NAME", f"sbx-{SANDBOX}-gold-etl")
CATALOG = os.environ.get("DATA_CATALOG_NAME", f"sbx-{SANDBOX}-catalog")
SCHEDULE = os.environ.get("PIPELINE_SCHEDULE", "@once").strip() or "@once"


# ---------------------------------------------------------------------------
# OCI clients, as the container itself
# ---------------------------------------------------------------------------
def _auth():
    import oci
    if os.environ.get("OCI_RESOURCE_PRINCIPAL_VERSION"):
        signer = oci.auth.signers.get_resource_principals_signer()
        return {"config": {"region": signer.region, "tenancy": signer.tenancy_id}, "signer": signer}
    return {"config": oci.config.from_file()}


def _client(cls):
    return cls(**_auth())


def _region():
    return _auth()["config"]["region"]


# ---------------------------------------------------------------------------
# 1. raw: synthetic device readings, the way a fleet would send them
# ---------------------------------------------------------------------------
def land_raw_readings(**ctx):
    import oci
    os_client = _client(oci.object_storage.ObjectStorageClient)
    ns = NAMESPACE or os_client.get_namespace().data
    random.seed(42)
    sites = {"phx-1": ["dev-001", "dev-002", "dev-003"], "ams-2": ["dev-101", "dev-102"], "syd-3": ["dev-201"]}
    start = datetime.utcnow().replace(minute=0, second=0, microsecond=0) - timedelta(days=2)
    files = 0
    for day in range(2):
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["device_id", "site", "ts", "temperature_c", "humidity_pct", "battery_pct", "event"])
        for site, devices in sites.items():
            for dev in devices:
                battery = 100.0 - random.random() * 30
                base_t = 20 + hash(dev) % 8
                t = start + timedelta(days=day)
                while t < start + timedelta(days=day + 1):
                    # a device sends every 2 minutes, sleeps for 15-40 minutes a few times a day
                    if random.random() < 0.02:
                        t += timedelta(minutes=random.randint(15, 40))
                        continue
                    hour = t.hour + t.minute / 60
                    temp = base_t + 4 * math.sin((hour - 6) / 24 * 2 * math.pi) + random.gauss(0, 0.4)
                    event = "reading"
                    if random.random() < 0.004:          # a spike the z-score should catch
                        temp += random.choice([-1, 1]) * random.uniform(6, 12)
                    if random.random() < 0.001:          # a glitch the cleaner should null out
                        temp = 999.0
                    if dev == "dev-102" and random.random() < 0.003:
                        event = "fault"
                    battery = max(3.0, battery - 0.02)
                    row = [dev, site, t.strftime("%Y-%m-%d %H:%M:%S"), round(temp, 2),
                           round(45 + random.gauss(0, 5), 1), round(battery, 1), event]
                    w.writerow(row)
                    if random.random() < 0.01:           # retransmit: same reading twice
                        w.writerow(row)
                    t += timedelta(minutes=2)
        name = f"raw/readings_{(start + timedelta(days=day)).date()}.csv"
        os_client.put_object(ns, BUCKET, name, buf.getvalue().encode())
        files += 1
    print(f"landed {files} raw files in oci://{BUCKET}@{ns}/raw/")
    return ns


# ---------------------------------------------------------------------------
# 2. Spark on Data Flow: the gold tables
# ---------------------------------------------------------------------------
def run_gold_etl(**ctx):
    import oci
    df = _client(oci.data_flow.DataFlowClient)
    ns = ctx["ti"].xcom_pull(task_ids="land_raw_readings") or NAMESPACE
    apps = [a for a in df.list_applications(COMPARTMENT, display_name=DATAFLOW_APP).data
            if a.lifecycle_state == "ACTIVE"]
    if not apps:
        raise RuntimeError(f"Data Flow application {DATAFLOW_APP} not found in the sandbox compartment")
    run = df.create_run(oci.data_flow.models.CreateRunDetails(
        compartment_id=COMPARTMENT, application_id=apps[0].id,
        display_name=f"gold-etl {datetime.utcnow():%Y-%m-%d %H:%M}",
        arguments=["--bucket", BUCKET, "--namespace", ns])).data
    print(f"Data Flow run {run.id} started")
    deadline = time.time() + 45 * 60
    while time.time() < deadline:
        r = df.get_run(run.id).data
        if r.lifecycle_state in ("SUCCEEDED", "FAILED", "CANCELED", "STOPPED"):
            print(f"run finished: {r.lifecycle_state} {r.lifecycle_details or ''}")
            if r.lifecycle_state != "SUCCEEDED":
                raise RuntimeError(f"Data Flow run {r.lifecycle_state}: {r.lifecycle_details}")
            return run.id
        time.sleep(30)
    raise TimeoutError("Data Flow run did not finish in 45 minutes")


# ---------------------------------------------------------------------------
# 3. Data Catalog: register the bucket and harvest, so the gold tables show up
# ---------------------------------------------------------------------------
def harvest_catalog(**ctx):
    import oci
    dc = _client(oci.data_catalog.DataCatalogClient)
    ns = ctx["ti"].xcom_pull(task_ids="land_raw_readings") or NAMESPACE
    cats = [c for c in dc.list_catalogs(compartment_id=COMPARTMENT, display_name=CATALOG).data
            if c.lifecycle_state == "ACTIVE"]
    if not cats:
        raise RuntimeError(f"Data Catalog {CATALOG} not found in the sandbox compartment")
    cid = cats[0].id
    # Type names repeat across parents ("Resource Principal" exists for Object
    # Storage and for Data Integration), so keep every type and pick by parent.
    all_types = list(oci.pagination.list_call_get_all_results(dc.list_types, cid, limit=500).data)
    asset_type = next(t.key for t in all_types if t.type_category == "dataAsset" and t.name == "Oracle Object Storage")
    rp = [t for t in all_types if t.type_category == "connection" and t.name == "Resource Principal"]
    print("resource principal connection types:", [(t.key, t.parent_type_name) for t in rp])
    conn_type = next((t.key for t in rp if (t.parent_type_name or "") == "Oracle Object Storage"), None) or rp[0].key

    assets = [a for a in dc.list_data_assets(cid, display_name=BUCKET).data.items]
    if assets:
        asset_key = assets[0].key
    else:
        asset_key = dc.create_data_asset(cid, oci.data_catalog.models.CreateDataAssetDetails(
            display_name=BUCKET, type_key=asset_type,
            description=f"Sandbox {SANDBOX} data bucket: raw/ and gold/",
            # Data Catalog addresses Object Storage through its Swift-compatible
            # host, with no path: the native endpoint and ".../v1" are both
            # rejected with DCAT-11111 (verified against a live catalog).
            properties={"default": {"url": f"https://swiftobjectstorage.{_region()}.oraclecloud.com", "namespace": ns}})).data.key
    conns = dc.list_connections(cid, asset_key).data.items
    if conns:
        conn_key = conns[0].key
    else:
        conn_key = dc.create_connection(cid, asset_key, oci.data_catalog.models.CreateConnectionDetails(
            display_name="resource-principal", type_key=conn_type, is_default=True,
            properties={"default": {"ociRegion": _region(), "ociCompartment": COMPARTMENT}})).data.key

    jds = dc.list_job_definitions(cid, data_asset_key=asset_key, display_name="harvest-gold").data.items
    if jds:
        jd_key = jds[0].key
    else:
        jd_key = dc.create_job_definition(cid, oci.data_catalog.models.CreateJobDefinitionDetails(
            display_name="harvest-gold", job_type="HARVEST", data_asset_key=asset_key,
            connection_key=conn_key, is_incremental=False, is_sample_data_extracted=False)).data.key
    jobs = dc.list_jobs(cid, job_definition_key=jd_key).data.items
    job_key = jobs[0].key if jobs else dc.create_job(cid, oci.data_catalog.models.CreateJobDetails(
        display_name="harvest-gold", job_definition_key=jd_key)).data.key
    ex = dc.create_job_execution(cid, job_key, oci.data_catalog.models.CreateJobExecutionDetails(job_type="HARVEST")).data
    print(f"harvest started: job {job_key} execution {ex.key}")
    deadline = time.time() + 20 * 60
    while time.time() < deadline:
        e = dc.get_job_execution(cid, job_key, ex.key).data
        if e.lifecycle_state in ("SUCCEEDED", "FAILED", "CANCELED", "SUCCEEDED_WITH_WARNINGS"):
            print(f"harvest {e.lifecycle_state}: {e.error_message or ''}")
            if e.lifecycle_state == "FAILED":
                # The bucket is registered in the catalog either way. A harvest
                # that fails inside the catalog service is metadata, not data:
                # the gold tables are already correct, so say so and move on
                # rather than mark the whole pipeline run failed.
                print(f"WARNING: catalog harvest failed in the service ({e.error_message}); "
                      f"the data asset {BUCKET} is registered, harvest it from the console")
                return f"registered; harvest failed: {(e.error_message or '')[:120]}"
            return e.key
        time.sleep(20)
    print("WARNING: catalog harvest still running after 20 minutes; it continues in the service")
    return "registered; harvest still running"


# ---------------------------------------------------------------------------
# 4. Oracle: the gold tables as real tables in the sandbox Autonomous Database
# ---------------------------------------------------------------------------
GOLD_TABLES = {
    "TELEMETRY_DAILY": ("""day date, site varchar2(50), device_id varchar2(50), readings number,
        temp_avg_c number, temp_min_c number, temp_max_c number, temp_p95_c number,
        humidity_avg_pct number, battery_min_pct number, anomalies number, sessions number,
        faults number, health varchar2(20)""", "gold_oracle/telemetry_daily/"),
    "TELEMETRY_SESSIONS": ("""day date, device_id varchar2(50), session_id varchar2(80),
        started_at timestamp, ended_at timestamp, readings number, temp_avg_c number,
        anomalies number, duration_min number""", "gold_oracle/telemetry_sessions/"),
}


def _adb_dsn(connect: str) -> str:
    """Autonomous Database only speaks TLS; host:port/service must become a TCPS descriptor."""
    if connect.lstrip().startswith("("):
        return connect
    host_port, service = connect.split("/", 1)
    host, port = host_port.split(":")
    return (f"(description=(retry_count=5)(retry_delay=3)(address=(protocol=tcps)(port={port})(host={host}))"
            f"(connect_data=(service_name={service}))(security=(ssl_server_dn_match=yes)))")


def load_gold_to_oracle(**ctx):
    connect, pw = os.environ.get("ADB_CONNECT_STRING"), os.environ.get("ADB_ADMIN_PASSWORD")
    if not (connect and pw):
        print("no database in this sandbox; the gold tables stay in Object Storage only")
        return "skipped"
    import oracledb
    ns = ctx["ti"].xcom_pull(task_ids="land_raw_readings") or NAMESPACE
    base = f"https://objectstorage.{_region()}.oraclecloud.com/n/{ns}/b/{BUCKET}/o/"
    with oracledb.connect(user="ADMIN", password=pw, dsn=_adb_dsn(connect)) as db:
        cur = db.cursor()
        # The database reads the bucket as itself (resource principal), no keys.
        try:
            cur.execute("begin dbms_cloud_admin.enable_resource_principal(); end;")
        except oracledb.DatabaseError as e:
            if "ORA-20000" not in str(e) and "already" not in str(e).lower():
                raise
        loaded = {}
        for table, (cols, prefix) in GOLD_TABLES.items():
            cur.execute("select count(*) from user_tables where table_name = :t", t=table)
            if not cur.fetchone()[0]:
                cur.execute(f"create table {table} ({cols})")
            cur.execute(f"truncate table {table}")
            cur.execute("""begin dbms_cloud.copy_data(table_name => :t, credential_name => 'OCI$RESOURCE_PRINCIPAL',
                             file_uri_list => :u, format => json_object('type' value 'parquet', 'schema' value 'first')); end;""",
                        t=table, u=base + prefix + "*.parquet")
            cur.execute(f"select count(*) from {table}")
            loaded[table] = cur.fetchone()[0]
        db.commit()
    print(f"loaded into the database: {loaded}")
    return loaded


with DAG(
    dag_id="telemetry_gold",
    description="raw readings -> Spark gold tables -> Data Catalog",
    schedule=SCHEDULE,
    start_date=datetime(2024, 1, 1) if SCHEDULE == "@once" else datetime.utcnow() - timedelta(minutes=1),
    catchup=SCHEDULE == "@once",
    max_active_runs=1,
    is_paused_upon_creation=False,
    default_args={"retries": 1, "retry_delay": timedelta(minutes=2)},
    tags=["telemetry", "gold", "data-flow", "data-catalog"],
) as dag:
    land = PythonOperator(task_id="land_raw_readings", python_callable=land_raw_readings)
    etl = PythonOperator(task_id="run_gold_etl", python_callable=run_gold_etl)
    harvest = PythonOperator(task_id="harvest_catalog", python_callable=harvest_catalog)
    oracle = PythonOperator(task_id="load_gold_to_oracle", python_callable=load_gold_to_oracle)
    land >> etl >> [harvest, oracle]
