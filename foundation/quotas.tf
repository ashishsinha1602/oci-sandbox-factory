# Hard caps on the sandbox tree. Quotas are tenancy-level IAM resources.
# Off by default (enable_quotas = false) until the names are confirmed on
# the target tenancy: `oci limits service list` / `oci limits value list`.

locals {
  q    = var.quota_limits
  root = oci_identity_compartment.root.name

  quota_statements = {
    database = [
      "set database quota atp-ecpu-count to ${local.q.atp_ecpu} in compartment ${local.root}",
      "set database quota adw-ecpu-count to ${local.q.adw_ecpu} in compartment ${local.root}",
      "set database quota adb-free-count to ${local.q.adb_free} in compartment ${local.root}",
      "zero database quotas /*dedicated*/ in compartment ${local.root}",
      "zero database quotas /*exacc*/ in compartment ${local.root}",
    ]
    compute = [
      "set compute-core quota standard-a1-core-count to ${local.q.a1_ocpu} in compartment ${local.root}",
      "set compute-memory quota standard-a1-memory-count to ${local.q.a1_memory_gb} in compartment ${local.root}",
      "zero compute-core quotas /*gpu*/ in compartment ${local.root}",
    ]
    container-engine = [
      "set container-engine quota cluster-count to ${local.q.oke_clusters} in compartment ${local.root}",
    ]
    streaming = [
      "set streaming quota partition-count to ${local.q.stream_partitions} in compartment ${local.root}",
    ]
  }
}

resource "oci_limits_quota" "sandbox" {
  provider = oci.home
  for_each = var.enable_quotas ? local.quota_statements : {}

  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-${each.key}"
  description    = "Sandbox factory cap for ${each.key}."
  statements     = each.value
  freeform_tags  = local.freeform_tags
}
