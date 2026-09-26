"""Query the sandbox's Iceberg tables (catalog "lake") with Spark SQL.

Run this Data Flow application with the parameter sql, for example
    SELECT * FROM lake.worldbank.population ORDER BY year DESC LIMIT 20
With no sql it lists every table with its row count. The rows are printed in
the run log and written as CSV to the sandbox bucket under query-results/.
"""
import datetime
import sys

from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("iceberg-query").getOrCreate()
sql = " ".join(a for a in sys.argv[1:] if a.strip()).strip()
if not sql or sql.upper() == "TABLES":
    rows = []
    for ns in [r[0] for r in spark.sql("SHOW NAMESPACES IN lake").collect()]:
        for t in spark.sql(f"SHOW TABLES IN lake.{ns}").collect():
            name = f"lake.{ns}.{t.tableName}"
            rows.append((name, spark.table(name).count()))
    df = spark.createDataFrame(rows or [("(no Iceberg tables yet)", 0)], ["table", "rows"])
else:
    df = spark.sql(sql)
df.show(200, truncate=False)
out = "oci://{}@{}/query-results/{:%Y%m%dT%H%M%S}".format(
    spark.conf.get("DATA_BUCKET"), spark.conf.get("OBJECT_NAMESPACE"), datetime.datetime.utcnow())
df.coalesce(1).write.option("header", True).csv(out)
print("results written to", out)
