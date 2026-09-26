terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "tables" {
  description = "Tables to create. ddl is a full CREATE TABLE statement; {name} is replaced by the prefixed table name."
  type = list(object({
    name    = string
    ddl     = string
    read    = optional(number, 5)
    write   = optional(number, 5)
    storage = optional(number, 1)
  }))
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }

# OCI NoSQL Database Cloud Service: serverless key-value / JSON document tables.
# On-demand capacity keeps a sandbox cheap - you pay for what you read and write
# rather than for a provisioned cluster sitting idle for three days.
resource "oci_nosql_table" "this" {
  for_each = { for t in var.tables : t.name => t }

  compartment_id = var.compartment_id
  name           = "${replace(var.name, "-", "_")}_${each.value.name}"
  ddl_statement  = replace(each.value.ddl, "{name}", "${replace(var.name, "-", "_")}_${each.value.name}")
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags

  table_limits {
    max_read_units     = each.value.read
    max_write_units    = each.value.write
    max_storage_in_gbs = each.value.storage
    capacity_mode      = "PROVISIONED"
  }
}

output "tables" {
  value = [for t in oci_nosql_table.this : t.name]
}

output "table_ids" {
  value = { for k, t in oci_nosql_table.this : k => t.id }
}

output "compartment_id" {
  value = var.compartment_id
}
