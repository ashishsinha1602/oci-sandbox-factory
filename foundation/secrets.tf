# One Vault for every per-sandbox secret (today: the Kafka superuser password
# the Streaming service generates). A DEFAULT vault with a software key costs
# nothing to keep; sandboxes create their secrets in their own compartment
# under this key, which is why the worker may "use" it.
# The vault holds each Kafka sandbox's superuser password. Kafka is not part of
# Always Free, so the Free Tier edition creates no vault (and cannot hit the
# tenancy's vault limit, which counts vaults still pending deletion for 7 days).
resource "oci_kms_vault" "secrets" {
  count          = (local.free || !var.enable_vault) ? 0 : 1
  compartment_id = oci_identity_compartment.control.id
  display_name   = "${local.prefix}-secrets"
  vault_type     = "DEFAULT"
}

# A new vault's management endpoint is not in DNS for a minute or two after the
# vault reports ACTIVE; creating the key at once failed a fresh install with
# "lookup <vault>-management.kms...: no such host". Wait, then create the key.
resource "time_sleep" "vault_dns" {
  count           = (local.free || !var.enable_vault) ? 0 : 1
  create_duration = "180s"
  triggers = {
    management_endpoint = oci_kms_vault.secrets[0].management_endpoint
  }
}

resource "oci_kms_key" "secrets" {
  count               = (local.free || !var.enable_vault) ? 0 : 1
  compartment_id      = oci_identity_compartment.control.id
  display_name        = "${local.prefix}-secrets-key"
  management_endpoint = time_sleep.vault_dns[0].triggers["management_endpoint"]
  protection_mode     = "SOFTWARE"
  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

# Streaming with Apache Kafka attaches its brokers to the shared VCN: needed for every
# cluster, vault or not (without it a cluster fails with "Subnet ... not accessible";
# clean install without a vault, 2026-09-30).
resource "oci_identity_policy" "kafka_network" {
  count          = local.free ? 0 : 1
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${local.prefix}-kafka-network"
  description    = "Streaming with Apache Kafka attaches each sandbox cluster to the shared VCN; the public add-on needs the sandboxes side too."
  statements = [
    "allow service rawfka to use virtual-network-family in compartment id ${oci_identity_compartment.control.id}",
    "allow service rawfka to use virtual-network-family in compartment id ${oci_identity_compartment.sandboxes.id}",
  ]
}

# ...and writes each cluster's superuser password into the sandbox's secret, which
# is what the public add-on's SASL login needs. Only with the vault.
resource "oci_identity_policy" "kafka_superuser" {
  count          = (local.free || !var.enable_vault) ? 0 : 1
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${local.prefix}-kafka-superuser"
  description    = "Streaming with Apache Kafka writes each sandbox superuser password into that sandbox Vault secret."
  statements = [
    "allow service rawfka to {SECRET_UPDATE} in compartment id ${oci_identity_compartment.sandboxes.id}",
    "allow service rawfka to use secrets in compartment id ${oci_identity_compartment.sandboxes.id} where request.operation = 'UpdateSecret'",
    "allow service rawfka to read secrets in compartment id ${oci_identity_compartment.sandboxes.id}",
  ]
}
