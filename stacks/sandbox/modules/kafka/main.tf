terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "mode" { type = string }
variable "topics" { type = list(string) }
variable "partitions" { type = number }
variable "kafka_version" { type = string }
variable "subnet_id" { type = string }
variable "vault_id" {
  description = "Shared Vault that holds each cluster's superuser secret. Empty disables the superuser and the public endpoint."
  type        = string
  default     = ""
}
variable "key_id" {
  description = "Encryption key in that vault."
  type        = string
  default     = ""
}
variable "public_cidrs" {
  description = "Who may reach the public Kafka endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
variable "storage_gb" {
  description = "Broker storage. 50 GB is the smallest a cluster accepts."
  type        = number
  default     = 50
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }

locals {
  streaming = var.mode == "streaming"
}

# --- mode = streaming: OCI Streaming pool with the Kafka-compatible API ------
# Serverless; billed per GB in/out and per partition-hour. Clients use SASL
# PLAIN with <tenancy>/<user>/<pool-ocid> as username and an auth token.

resource "oci_streaming_stream_pool" "this" {
  count          = local.streaming ? 1 : 0
  compartment_id = var.compartment_id
  name           = "${var.name}-kafka"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags

  kafka_settings {
    auto_create_topics_enable = true
    log_retention_hours       = 24
    num_partitions            = var.partitions
  }
}

resource "oci_streaming_stream" "topics" {
  for_each = local.streaming ? toset(var.topics) : toset([])

  name               = each.key
  stream_pool_id     = oci_streaming_stream_pool.this[0].id
  partitions         = var.partitions
  retention_in_hours = 24
  defined_tags       = var.defined_tags
  freeform_tags      = var.freeform_tags
}

# --- mode = cluster: managed Kafka, DEVELOPMENT tier -----------------------
# Real brokers in the private subnet. Costs per broker-hour; use for demos
# that need consumer groups, transactions or Kafka Connect.

resource "oci_managed_kafka_kafka_cluster_config" "this" {
  count          = local.streaming ? 0 : 1
  compartment_id = var.compartment_id
  display_name   = "${var.name}-kafka-config"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags

  latest_config {
    properties = {
      "auto.create.topics.enable" = "true"
      "num.partitions"            = tostring(var.partitions)
      "log.retention.hours"       = "24"
    }
  }

  # A re-apply (a retry after a failed build) must not touch the config: the
  # provider bumps its version during the apply and the cluster, planned
  # against the old version, fails with "inconsistent final plan".
  lifecycle {
    ignore_changes = [latest_config]
  }
}

resource "oci_managed_kafka_kafka_cluster" "this" {
  count             = local.streaming ? 0 : 1
  compartment_id    = var.compartment_id
  display_name      = "${var.name}-kafka"
  cluster_type      = "DEVELOPMENT"
  coordination_type = "KRAFT"
  kafka_version     = var.kafka_version

  cluster_config_id = oci_managed_kafka_kafka_cluster_config.this[0].id
  # Version 1 is what a freshly created config has, and the number is known at
  # plan time; reading it from the config resource is what tripped the
  # provider's "inconsistent final plan" on every retry.
  cluster_config_version = 1

  access_subnets {
    subnets = [var.subnet_id]
  }

  broker_shape {
    node_count          = 1
    ocpu_count          = 1
    storage_size_in_gbs = var.storage_gb
  }

  # A cluster takes 20-30 minutes to come up; the provider's default 20-minute
  # wait gave up on a cluster that was still creating ("Operation Timeout").
  timeouts {
    create = "90m"
    delete = "60m"
  }

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

# --- superuser + public endpoint (cluster mode) ------------------------------
# A cluster is private to the VCN and authenticates with mTLS or SASL/SCRAM.
# Three more pieces make it something a user can reach from a laptop with a
# username and password:
#   1. a Vault secret, which the service fills with a generated superuser
#      password when the superuser is enabled (policy: service rawfka may
#      UpdateSecret in the sandboxes compartment);
#   2. the superuser itself;
#   3. the PUBLICCONNECTIVITY add-on, a public bootstrap URL limited to the
#      CIDRs given, authenticating with SASL/SCRAM.
# The worker reads the secret after the apply and puts the credentials on the
# sandbox card.
locals {
  superuser = !local.streaming && var.vault_id != "" && var.key_id != ""
}

resource "random_id" "secret" {
  count       = local.superuser ? 1 : 0
  byte_length = 3
}

resource "oci_vault_secret" "superuser" {
  count          = local.superuser ? 1 : 0
  compartment_id = var.compartment_id
  vault_id       = var.vault_id
  key_id         = var.key_id
  # A deleted secret keeps its name for a while, so a rebuilt sandbox needs a
  # fresh one.
  secret_name = "${var.name}-kafka-superuser-${random_id.secret[0].hex}"
  description = "SASL/SCRAM superuser password for ${var.name}-kafka, written by the Kafka service."
  secret_content {
    content_type = "BASE64"
    content      = base64encode("pending")
  }
  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
  lifecycle {
    ignore_changes = [secret_content]
  }
}

resource "oci_managed_kafka_kafka_cluster_superusers_management" "this" {
  count            = local.superuser ? 1 : 0
  kafka_cluster_id = oci_managed_kafka_kafka_cluster.this[0].id
  compartment_id   = var.compartment_id
  secret_id        = oci_vault_secret.superuser[0].id
  enable_superuser = true

  timeouts {
    create = "45m"
    update = "45m"
  }
}

# The public endpoint add-on. The OCI provider reports "Work Request error"
# with no message while the service finishes the add-on, and fails even after
# the orphan is removed and the stack re-applied, so by default the factory
# installs it through the SDK after the apply (sandbox_factory.kafka_public_addon).
variable "public_addon_in_terraform" {
  type    = bool
  default = false
}

output "public_cidrs" {
  value = var.public_cidrs
}

resource "oci_managed_kafka_kafka_cluster_addon" "public" {
  count                    = local.superuser && var.public_addon_in_terraform ? 1 : 0
  kafka_cluster_id         = oci_managed_kafka_kafka_cluster.this[0].id
  addon_type               = "PUBLICCONNECTIVITY"
  authentication_mechanism = "SASL" # the API's spelling of SASL/SCRAM; "SASL_SCRAM" is rejected
  name                     = "${var.name}-public"
  description              = "Public bootstrap for ${var.name}, SASL/SCRAM."
  network_cidrs            = var.public_cidrs

  timeouts {
    create = "45m"
    delete = "45m"
  }

  depends_on = [oci_managed_kafka_kafka_cluster_superusers_management.this]
}

output "bootstrap_servers" {
  value = local.streaming ? try(oci_streaming_stream_pool.this[0].kafka_settings[0].bootstrap_servers, "") : try(oci_managed_kafka_kafka_cluster.this[0].kafka_bootstrap_urls[0].url, "")
}

output "pool_id" {
  value = local.streaming ? oci_streaming_stream_pool.this[0].id : null
}

output "cluster_id" {
  value = local.streaming ? null : oci_managed_kafka_kafka_cluster.this[0].id
}

output "public_bootstrap" {
  value = local.superuser ? try(oci_managed_kafka_kafka_cluster_addon.public[0].bootstrap_url, "") : ""
}

output "superuser_secret_id" {
  value = local.superuser ? oci_vault_secret.superuser[0].id : null
}

output "auth_note" {
  value = local.streaming ? "SASL_SSL/PLAIN. username = <tenancy-name>/<user-name>/${oci_streaming_stream_pool.this[0].id}, password = an OCI auth token." : "mTLS with the cluster client certificate bundle, or SASL superuser (see cluster superusers)."
}
