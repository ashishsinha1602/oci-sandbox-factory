terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "jobs" {
  description = <<-EOT
    Spark applications. This is OCI's equivalent of an AWS Glue ETL job: managed
    Spark, billed per run, nothing provisioned between runs. file_uri points at
    the job in Object Storage, e.g. oci://bucket@namespace/etl.py
  EOT
  type = list(object({
    name           = string
    file_uri       = string
    language       = optional(string, "PYTHON")
    spark_version  = optional(string, "3.5.0")
    driver_shape   = optional(string, "VM.Standard.E4.Flex")
    executor_shape = optional(string, "VM.Standard.E4.Flex")
    num_executors  = optional(number, 1)
    ocpus          = optional(number, 1)
    memory_gb      = optional(number, 16)
    arguments      = optional(list(string), [])
    warehouse_uri  = optional(string)
    # extra Spark settings, and Iceberg: the runtime from Maven and a catalog
    # named "lake" whose tables live in the sandbox bucket under iceberg/
    spark_conf = optional(map(string), {})
    iceberg    = optional(bool, false)
    # The job's code, inline. Terraform drops attributes a module's object
    # type does not declare, so without this line an inline script silently
    # became an empty file_uri: "Missing fileUri" from Data Flow.
    script = optional(string, "")
  }))
}
variable "scripts_bucket" {
  description = "Bucket that holds job scripts uploaded with the request."
  type        = string
  default     = ""
}
variable "namespace" {
  type    = string
  default = ""
}

variable "logs_bucket_uri" {
  description = "Where Data Flow writes run logs, e.g. oci://bucket@namespace/"
  type        = string
}
variable "injected_env" {
  type    = map(string)
  default = {}
}
variable "private_subnet_id" {
  description = "The install's private subnet. With db_hosts, a Data Flow private endpoint is created in it so a run reaches the sandbox database, which is private and never public."
  type        = string
  default     = ""
}
variable "db_hosts" {
  description = "Private hostnames of the databases a job may use: the shared database that holds this sandbox's schema, its own databases. Each is a DNS zone of the private endpoint; with any, the Oracle JDBC driver goes on the Spark classpath."
  type        = list(string)
  default     = []
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }

# Data Flow checks that the script exists when the application is created, so a
# job whose script is uploaded later fails with FILE_URL_INVALID. When a request
# carries the script inline, put it in the bucket first and point the job at it.
resource "oci_objectstorage_object" "script" {
  for_each = {
    for j in var.jobs : j.name => j
    if try(j.script, "") != "" && var.scripts_bucket != ""
  }

  namespace = var.namespace
  bucket    = var.scripts_bucket
  object    = "${each.value.name}.py"
  content   = each.value.script
}

# The sandbox database is reachable only inside the VCN, and a Data Flow run
# starts outside it: a private endpoint (one per sandbox with a database and a
# job, five per tenancy) carries the run in. A private Autonomous Database is
# named by its full host name in dns_zones (zones under oraclecloud.com must be
# complete). With a database, Spark also gets Oracle's JDBC driver: Data Flow
# ships it only when asked, and without it a job writing to the database dies
# with ClassNotFoundException oracle.jdbc.OracleDriver.
locals {
  db      = length(var.db_hosts) > 0 && var.private_subnet_id != ""
  db_conf = length(var.db_hosts) > 0 ? { "spark.oracle.datasource.enabled" = "true" } : {}
  # ADB_CONNECT_STRING is host:port/service; the database accepts only TLS, so
  # the job gets a ready JDBC URL (spark.sandbox.ADB_JDBC_URL) with a TCPS descriptor.
  cs       = lookup(var.injected_env, "ADB_CONNECT_STRING", "")
  cs_hp    = length(split("/", local.cs)) > 1 ? split("/", local.cs)[0] : ""
  cs_host  = length(split(":", local.cs_hp)) > 1 ? split(":", local.cs_hp)[0] : ""
  cs_port  = length(split(":", local.cs_hp)) > 1 ? split(":", local.cs_hp)[1] : "1521"
  cs_srv   = length(split("/", local.cs)) > 1 ? split("/", local.cs)[1] : ""
  jdbc_url = local.cs == "" ? "" : (startswith(trimspace(local.cs), "(") ? "jdbc:oracle:thin:@${local.cs}" : (local.cs_host == "" ? "" : "jdbc:oracle:thin:@(description=(retry_count=5)(retry_delay=3)(address=(protocol=tcps)(port=${local.cs_port})(host=${local.cs_host}))(connect_data=(service_name=${local.cs_srv}))(security=(ssl_server_dn_match=yes)))"))
  jdbc     = local.jdbc_url == "" ? {} : { "spark.sandbox.ADB_JDBC_URL" = local.jdbc_url }
}

resource "oci_dataflow_private_endpoint" "db" {
  count = local.db ? 1 : 0

  compartment_id = var.compartment_id
  display_name   = "${var.name}-dataflow"
  description    = "Lets this sandbox's Spark runs reach its database on the private subnet."
  subnet_id      = var.private_subnet_id
  dns_zones      = var.db_hosts
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags
}

# A Data Flow application is a job definition, not a running cluster. Spark is
# started for a run and torn down afterwards, so an idle job costs nothing and
# consumes no quota - the same reason Functions suit a sandbox.
resource "oci_dataflow_application" "this" {
  for_each = { for j in var.jobs : j.name => j }

  compartment_id = var.compartment_id
  display_name   = "${var.name}-${each.value.name}"
  # Prefer the script uploaded with the request over a URI the caller supplied.
  file_uri             = try(each.value.script, "") != "" && var.scripts_bucket != "" ? "oci://${var.scripts_bucket}@${var.namespace}/${each.value.name}.py" : each.value.file_uri
  language             = each.value.language
  spark_version        = each.value.spark_version
  num_executors        = each.value.num_executors
  driver_shape         = each.value.driver_shape
  executor_shape       = each.value.executor_shape
  arguments            = each.value.arguments
  logs_bucket_uri      = var.logs_bucket_uri
  warehouse_bucket_uri = each.value.warehouse_uri
  private_endpoint_id  = local.db ? oci_dataflow_private_endpoint.db[0].id : null
  # Spark exposes only spark.* properties: the sandbox settings become spark.sandbox.<KEY>
  configuration = merge({ for k, v in var.injected_env : "spark.sandbox.${k}" => v }, local.jdbc, local.db_conf, each.value.spark_conf, each.value.iceberg ? local.iceberg_conf : {})
  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags

  depends_on = [oci_objectstorage_object.script]

  driver_shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory_gb
  }

  executor_shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory_gb
  }
}

# With any Iceberg job, one more application to look at the tables: Spark SQL
# over the "lake" catalog, the sql parameter given at run time (the Athena
# counterpart, billed per run like the rest).
locals {
  iceberg = anytrue([for j in var.jobs : j.iceberg]) && var.scripts_bucket != ""
  iceberg_conf = {
    "spark.jars.packages"              = "org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.5.2"
    "spark.sql.extensions"             = "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions"
    "spark.sql.catalog.lake"           = "org.apache.iceberg.spark.SparkCatalog"
    "spark.sql.catalog.lake.type"      = "hadoop"
    "spark.sql.catalog.lake.warehouse" = "oci://${var.scripts_bucket}@${var.namespace}/iceberg"
  }
}

resource "oci_objectstorage_object" "iceberg_query" {
  count     = local.iceberg ? 1 : 0
  namespace = var.namespace
  bucket    = var.scripts_bucket
  object    = "iceberg-query.py"
  content   = file("${path.module}/iceberg_query.py")
}

resource "oci_dataflow_application" "iceberg_query" {
  count = local.iceberg ? 1 : 0

  compartment_id      = var.compartment_id
  display_name        = "${var.name}-iceberg-query"
  description         = "Run with the parameter sql to query the Iceberg tables; empty lists every table with its row count."
  file_uri            = "oci://${var.scripts_bucket}@${var.namespace}/iceberg-query.py"
  language            = "PYTHON"
  spark_version       = "3.5.0"
  num_executors       = 1
  driver_shape        = "VM.Standard.E4.Flex"
  executor_shape      = "VM.Standard.E4.Flex"
  arguments           = ["$${sql}"]
  logs_bucket_uri     = var.logs_bucket_uri
  private_endpoint_id = local.db ? oci_dataflow_private_endpoint.db[0].id : null
  configuration       = merge({ for k, v in var.injected_env : "spark.sandbox.${k}" => v }, local.jdbc, local.db_conf, local.iceberg_conf)
  defined_tags        = var.defined_tags
  freeform_tags       = var.freeform_tags

  parameters {
    name  = "sql"
    value = "TABLES"
  }
  driver_shape_config {
    ocpus         = 1
    memory_in_gbs = 16
  }
  executor_shape_config {
    ocpus         = 1
    memory_in_gbs = 16
  }
  depends_on = [oci_objectstorage_object.iceberg_query]
}

output "jobs" {
  value = concat([
    for k, a in oci_dataflow_application.this : {
      name     = a.display_name
      id       = a.id
      file_uri = a.file_uri
      language = a.language
    }
    ], [for a in oci_dataflow_application.iceberg_query : {
      name     = a.display_name
      id       = a.id
      file_uri = a.file_uri
      language = a.language
      query    = true
  }])
}
