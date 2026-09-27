terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "enabled" { type = bool }
variable "data_assets" {
  description = <<-EOT
    Sources to register in the catalog. An asset is a pointer to something the
    catalog can harvest - an Object Storage bucket, an Autonomous Database -
    which is how a Spark job discovers what it is allowed to read.
  EOT
  type = list(object({
    name        = string
    type_key    = string
    description = optional(string, "")
    properties  = optional(map(string), {})
  }))
  default = []
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }
# When data_assets is empty, every bucket of the sandbox is registered as an
# Object Storage asset with a resource-principal connection, so the catalog is
# never an empty shell. The worker then asks the catalog to harvest them.
variable "region" { type = string }
variable "namespace" {
  type    = string
  default = ""
}
variable "buckets" {
  description = "Bucket names of this sandbox, registered by default."
  type        = list(string)
  default     = []
}

# OCI Data Catalog is the counterpart to the AWS Glue Data Catalog: the
# metastore that says what data exists and where. Data Flow jobs read it to
# resolve a table name to a location and schema, which is the part that turns a
# pile of files in a bucket into something a Spark job can be pointed at.
resource "oci_datacatalog_catalog" "this" {
  count          = var.enabled ? 1 : 0
  compartment_id = var.compartment_id
  display_name   = "${var.name}-catalog"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags
}

# Type keys are per catalog and must be looked up. "Resource Principal" exists
# for several asset types; the one whose parent is the Object Storage asset type
# is the right one.
data "oci_datacatalog_catalog_types" "object_storage" {
  count         = var.enabled ? 1 : 0
  catalog_id    = oci_datacatalog_catalog.this[0].id
  type_category = "dataAsset"
  name          = "Oracle Object Storage"
}
locals {
  os_type_key = var.enabled ? one([for i in data.oci_datacatalog_catalog_types.object_storage[0].type_collection[0].items : i.key]) : ""
  # The for_each KEYS must be known at plan time: bucket names and asset names
  # are variables, so they are. The VALUES (type key, namespace) may only be
  # known at apply, which for_each allows. A guard like `namespace == "" ? [] : ...`
  # made the whole list unknown and the apply failed with "Invalid for_each argument".
  default_assets = length(var.data_assets) > 0 ? {} : { for b in var.buckets : b => {
    name        = b
    type_key    = local.os_type_key
    description = "Object Storage bucket ${b} of sandbox ${var.name}"
    # the value the catalog accepts for an Object Storage asset: the Swift endpoint, no path
    properties  = { "default.url" = "https://swiftobjectstorage.${var.region}.oraclecloud.com", "default.namespace" = var.namespace }
  } }
  assets = merge(local.default_assets, { for a in var.data_assets : a.name => a })
}

resource "oci_datacatalog_data_asset" "this" {
  for_each = var.enabled ? local.assets : {}

  catalog_id   = oci_datacatalog_catalog.this[0].id
  display_name = each.value.name
  type_key     = each.value.type_key
  description  = each.value.description
  properties   = each.value.properties
}

# The resource-principal connection, the filename pattern and the harvest are
# made by the worker after the apply: the catalog-types data source cannot tell
# the two "Resource Principal" connection types apart (no parent type key), and a
# harvest is a job run, which Terraform cannot express.
output "catalog" {
  value = var.enabled ? {
    id                = oci_datacatalog_catalog.this[0].id
    display_name      = oci_datacatalog_catalog.this[0].display_name
    number_of_objects = oci_datacatalog_catalog.this[0].number_of_objects
    service_url       = oci_datacatalog_catalog.this[0].service_api_url
    # the catalog's own console page. cloud.oracle.com/data-catalog/... is not a route (404).
    console_url       = oci_datacatalog_catalog.this[0].service_console_url
    # what is registered; the worker adds the connection, the pattern and the harvest
    assets = [for k, a in oci_datacatalog_data_asset.this : { name = k, key = a.key, type_key = a.type_key }]
  } : null
}

output "data_assets" {
  value = [for k, a in oci_datacatalog_data_asset.this : { name = k, key = a.key }]
}
