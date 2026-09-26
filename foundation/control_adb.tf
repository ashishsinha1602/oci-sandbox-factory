# Control database: Always Free ATP in sbx-control. Hosts the APEX front end,
# the sandbox request queue, and (hackathon mode) one schema per sandbox.

variable "enable_control_adb" {
  type    = bool
  default = true
}

variable "control_adb_allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "IP allow-list for the control database's public endpoint."
}

resource "random_password" "control_adb_admin" {
  count            = var.enable_control_adb ? 1 : 0
  length           = 20
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
  override_special = "#_-"
}

resource "oci_database_autonomous_database" "control" {
  count          = var.enable_control_adb ? 1 : 0
  compartment_id = oci_identity_compartment.control.id
  db_name        = upper(replace("${var.prefix}ctl", "-", ""))
  display_name   = "${var.prefix}-control-db"
  db_workload    = "OLTP"
  admin_password = random_password.control_adb_admin[0].result
  license_model  = "LICENSE_INCLUDED"

  is_free_tier             = true
  cpu_core_count           = 1
  data_storage_size_in_tbs = 1
  is_auto_scaling_enabled  = false

  whitelisted_ips             = var.control_adb_allowed_cidrs
  is_mtls_connection_required = false

  freeform_tags = local.freeform_tags

  lifecycle {
    # Always Free reports cpu_core_count 0 after creation; touching it is a 403.
    ignore_changes = [admin_password, cpu_core_count]
  }
}

output "control_adb" {
  value = var.enable_control_adb ? {
    id             = oci_database_autonomous_database.control[0].id
    db_name        = oci_database_autonomous_database.control[0].db_name
    connect_string = try(oci_database_autonomous_database.control[0].connection_strings[0].all_connection_strings["LOW"], "")
    apex_url       = try(oci_database_autonomous_database.control[0].connection_urls[0].apex_url, "")
    sql_web_url    = try(oci_database_autonomous_database.control[0].connection_urls[0].sql_dev_web_url, "")
    ords_url       = try(replace(oci_database_autonomous_database.control[0].connection_urls[0].apex_url, "/ords/apex", "/ords/"), "")
  } : null
}

output "control_adb_admin_password" {
  value     = var.enable_control_adb ? random_password.control_adb_admin[0].result : null
  sensitive = true
}

# Let the control database call OCI Generative AI as itself (resource
# principal), so Select AI in APEX needs no API keys.
resource "oci_identity_dynamic_group" "control_adb" {
  provider       = oci.home
  count          = var.enable_control_adb ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-control-adb-dg"
  description    = "The sandbox factory control database."
  matching_rule  = "resource.id = '${oci_database_autonomous_database.control[0].id}'"
  freeform_tags  = local.freeform_tags
}

resource "oci_identity_policy" "control_adb_genai" {
  provider       = oci.home
  count          = var.enable_control_adb ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-control-adb-genai"
  description    = "Control database may use Generative AI."
  statements     = ["allow dynamic-group ${oci_identity_dynamic_group.control_adb[0].name} to manage generative-ai-family in tenancy"]
  freeform_tags  = local.freeform_tags
}
