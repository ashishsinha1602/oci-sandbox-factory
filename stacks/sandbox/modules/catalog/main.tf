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

resource "oci_datacatalog_data_asset" "this" {
  for_each = var.enabled ? { for a in var.data_assets : a.name => a } : {}

  catalog_id   = oci_datacatalog_catalog.this[0].id
  display_name = each.value.name
  type_key     = each.value.type_key
  description  = each.value.description
  properties   = each.value.properties
}

output "catalog" {
  value = var.enabled ? {
    id                = oci_datacatalog_catalog.this[0].id
    display_name      = oci_datacatalog_catalog.this[0].display_name
    number_of_objects = oci_datacatalog_catalog.this[0].number_of_objects
    service_url       = oci_datacatalog_catalog.this[0].service_api_url
  } : null
}

output "data_assets" {
  value = [for k, a in oci_datacatalog_data_asset.this : { name = k, key = a.key }]
}
