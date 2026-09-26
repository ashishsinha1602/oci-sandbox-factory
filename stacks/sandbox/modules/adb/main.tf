terraform {
  required_providers {
    oci    = { source = "oracle/oci" }
    random = { source = "hashicorp/random" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "tier" { type = string }
variable "workload" { type = string }
variable "ecpu_count" { type = number }
variable "storage_gb" { type = number }
variable "vcn_id" { type = string }
variable "subnet_id" { type = string }
variable "allowed_cidrs" { type = list(string) }
# Oracle defaults a new Autonomous Database to 19c, which has no VECTOR datatype -
# AI Vector Search, and therefore every RAG starter, needs 23ai. Available on free
# tier too, so this costs nothing.
variable "db_version" {
  type    = string
  default = "23ai"
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }

locals {
  free = var.tier == "free"
  # Letters and digits only, starts with a letter, max 14 chars.
  db_name = substr(upper(replace(var.name, "-", "")), 0, 14)
  # Public, free-tier database: an allow-list lets us drop mTLS (no wallet).
  public_acl = local.free && length(var.allowed_cidrs) > 0
}

# 12-30 chars, upper + lower + digit, no double quote, must not contain "admin".
resource "random_password" "admin" {
  length           = 20
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
  override_special = "#_-"
}

resource "oci_core_network_security_group" "adb" {
  count          = local.free ? 0 : 1
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-adb"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "adb_in" {
  count                     = local.free ? 0 : 1
  network_security_group_id = oci_core_network_security_group.adb[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "SQL*Net TLS from anywhere inside the VCN (subnet security list already limits to VCN CIDR)."
  tcp_options {
    destination_port_range {
      min = 1521
      max = 1522
    }
  }
}

# A paid database's private endpoint keeps its VNIC attached to the security
# group for a minute or two after the database is gone, and deleting the
# group in that window fails with "still has vnics attached". This sleep sits
# between the two in the dependency chain, so on destroy Terraform removes the
# database, waits, then removes the group.
resource "time_sleep" "nsg_release" {
  count            = local.free ? 0 : 1
  destroy_duration = "180s"
  depends_on       = [oci_core_network_security_group.adb]
}

resource "oci_database_autonomous_database" "this" {
  compartment_id = var.compartment_id
  db_name        = local.db_name
  display_name   = var.name
  db_workload    = var.workload
  admin_password = random_password.admin.result
  license_model  = "LICENSE_INCLUDED"

  db_version               = var.db_version
  is_free_tier             = local.free
  cpu_core_count           = local.free ? 1 : null
  data_storage_size_in_tbs = local.free ? 1 : null
  compute_model            = local.free ? null : "ECPU"
  compute_count            = local.free ? null : var.ecpu_count
  data_storage_size_in_gb  = local.free ? null : var.storage_gb
  is_auto_scaling_enabled  = false

  # free  -> public endpoint, IP allow-list
  # paid  -> private endpoint in the shared private subnet
  whitelisted_ips = local.public_acl ? var.allowed_cidrs : null
  subnet_id       = local.free ? null : var.subnet_id
  nsg_ids         = local.free ? null : [oci_core_network_security_group.adb[0].id]

  depends_on                  = [time_sleep.nsg_release]
  private_endpoint_label      = local.free ? null : replace(var.name, "-", "")
  is_mtls_connection_required = local.public_acl || !local.free ? false : true

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags

  lifecycle {
    ignore_changes = [admin_password]
  }
}

output "id" {
  value = oci_database_autonomous_database.this.id
}

output "db_name" {
  value = oci_database_autonomous_database.this.db_name
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

# The "_low" service is the right default for app connections.
#
# A paid database sits on a private endpoint, but all_connection_strings still
# reports the public regional host, which resets the connection. Swap in the
# private endpoint FQDN so anything inside the VCN can actually connect.
locals {
  low_connect  = try(oci_database_autonomous_database.this.connection_strings[0].all_connection_strings["LOW"], "")
  low_host     = length(split("/", local.low_connect)) > 1 ? split("/", local.low_connect)[0] : ""
  private_fqdn = local.free ? "" : try(oci_database_autonomous_database.this.private_endpoint, "")

  # The port is NOT the same on both tiers. A public free-tier database serves
  # server-auth TLS on 1522 and mutual TLS on 1521; a private endpoint inverts
  # them - 1521 is server auth, 1522 is mutual. Handing a container the mutual
  # port gets ORA-12506, because it has no wallet. So read the port off the
  # profile that actually says SERVER rather than assuming either number.
  profiles = try(oci_database_autonomous_database.this.connection_strings[0].profiles, [])
  server_auth_low = [
    for p in local.profiles : p
    if upper(try(p.tls_authentication, "")) == "SERVER" && can(regex("(?i)_low$", try(p.display_name, "")))
  ]
  server_auth_port = try(regex("[(]port=([0-9]+)[)]", local.server_auth_low[0].value)[0], "1521")
}

output "connect_string" {
  value = (local.free || local.private_fqdn == "" || local.low_host == "") ? local.low_connect : replace(local.low_connect, local.low_host, "${local.private_fqdn}:${local.server_auth_port}")
}

output "sql_web_url" {
  value = try(oci_database_autonomous_database.this.connection_urls[0].sql_dev_web_url, "")
}

output "apex_url" {
  value = try(oci_database_autonomous_database.this.connection_urls[0].apex_url, "")
}

output "private_fqdn" {
  description = "Private endpoint host of a paid database (empty for Always Free); the app gateway proxies /ords/* to it."
  value       = local.private_fqdn
}
