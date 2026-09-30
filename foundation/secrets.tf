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
  display_name   = "${var.prefix}-secrets"
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
  display_name        = "${var.prefix}-secrets-key"
  management_endpoint = time_sleep.vault_dns[0].triggers["management_endpoint"]
  protection_mode     = "SOFTWARE"
  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

# Streaming with Apache Kafka writes each cluster's superuser password into
# the sandbox's secret. Tenancy-level, like the other service grants here.
resource "oci_identity_policy" "kafka_superuser" {
  count          = (local.free || !var.enable_vault) ? 0 : 1
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-kafka-superuser"
  description    = "Streaming with Apache Kafka writes each sandbox superuser password into that sandbox Vault secret."
  statements = [
    "allow service rawfka to {SECRET_UPDATE} in compartment id ${oci_identity_compartment.sandboxes.id}",
    "allow service rawfka to use secrets in compartment id ${oci_identity_compartment.sandboxes.id} where request.operation = 'UpdateSecret'",
    # brokers attach to the shared VCN in sbx-control; the public add-on needs the sandboxes side too
    "allow service rawfka to use virtual-network-family in compartment id ${oci_identity_compartment.control.id}",
    "allow service rawfka to use virtual-network-family in compartment id ${oci_identity_compartment.sandboxes.id}",
    "allow service rawfka to read secrets in compartment id ${oci_identity_compartment.sandboxes.id}",
  ]
}
