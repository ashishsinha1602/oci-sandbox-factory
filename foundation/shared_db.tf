# The install's shared database (v1.2). A sandbox that asks for a database gets
# a schema of its own in here - user, password, quota, SQL Developer Web, REST,
# an APEX workspace, Select AI over its own tables - instead of an Autonomous
# Database of its own that sits idle most of the time. The worker stops this
# database when no sandbox uses it and starts it again when one does.
#
# Standard edition only: private endpoint in the private subnet, reached through
# one API Gateway (the same /ords, /adb proxy a sandbox gateway gives a private
# database). The Free Tier edition needs nothing here: its control database, one
# of the two Always Free databases, doubles as the shared one.
#
# A sandbox that needs a whole database (a RAG starter's vector store, or "Own
# database" on the form) still gets one, exactly as before.

variable "shared_database" {
  type        = bool
  default     = true
  description = "Standard edition: one private Autonomous Database shared by every sandbox (a schema each) instead of a database per sandbox. Off = every sandbox with a database gets its own."
}

variable "shared_database_ecpus" {
  type        = number
  default     = 2
  description = "ECPUs of the shared database (2 is the minimum; auto-scaling lets it burst to three times this)."
}

variable "shared_database_storage_gb" {
  type        = number
  default     = 50
  description = "Storage of the shared database in GB, for every sandbox schema together."
}

locals {
  shared_db = !local.free && var.shared_database
}

resource "random_password" "shared_adb_admin" {
  count            = local.shared_db ? 1 : 0
  length           = 20
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
  override_special = "#_-"
}

resource "oci_core_network_security_group" "shared_adb" {
  count          = local.shared_db ? 1 : 0
  compartment_id = oci_identity_compartment.sandboxes.id
  vcn_id         = oci_core_vcn.sandbox.id
  display_name   = "${local.prefix}-shared-db"
  freeform_tags  = local.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "shared_adb_in" {
  count                     = local.shared_db ? 1 : 0
  network_security_group_id = oci_core_network_security_group.shared_adb[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "SQL*Net TLS and ORDS from inside the VCN (the subnet's security list limits it to the VCN)."
  tcp_options {
    destination_port_range {
      min = 443
      max = 1522
    }
  }
}

# the private endpoint keeps its VNIC on the group for a while after the database is gone
resource "time_sleep" "shared_adb_nsg_release" {
  count            = local.shared_db ? 1 : 0
  destroy_duration = "180s"
  depends_on       = [oci_core_network_security_group.shared_adb]
}

resource "oci_database_autonomous_database" "shared" {
  count          = local.shared_db ? 1 : 0
  compartment_id = oci_identity_compartment.sandboxes.id
  db_name        = substr(upper(replace("${local.prefix}shared", "-", "")), 0, 14)
  display_name   = "${local.prefix}-shared-db"
  db_workload    = "OLTP"
  admin_password = random_password.shared_adb_admin[0].result
  license_model  = "LICENSE_INCLUDED"

  db_version              = "23ai"
  compute_model           = "ECPU"
  compute_count           = var.shared_database_ecpus
  data_storage_size_in_gb = var.shared_database_storage_gb
  is_auto_scaling_enabled = true

  subnet_id                   = oci_core_subnet.private.id
  nsg_ids                     = [oci_core_network_security_group.shared_adb[0].id]
  private_endpoint_label      = replace("${local.prefix}shareddb", "-", "")
  is_mtls_connection_required = false

  freeform_tags = merge(local.freeform_tags, { role = "shared-database" })

  depends_on = [time_sleep.shared_adb_nsg_release]

  lifecycle {
    ignore_changes = [admin_password]
  }
}

locals {
  shared_low      = local.shared_db ? try(oci_database_autonomous_database.shared[0].connection_strings[0].all_connection_strings["LOW"], "") : ""
  shared_low_host = length(split("/", local.shared_low)) > 1 ? split("/", local.shared_low)[0] : ""
  shared_pe       = local.shared_db ? try(oci_database_autonomous_database.shared[0].private_endpoint, "") : ""
  shared_profiles = local.shared_db ? try(oci_database_autonomous_database.shared[0].connection_strings[0].profiles, []) : []
  shared_srv_low  = [for p in local.shared_profiles : p if upper(try(p.tls_authentication, "")) == "SERVER" && can(regex("(?i)_low$", try(p.display_name, "")))]
  shared_port     = try(regex("[(]port=([0-9]+)[)]", local.shared_srv_low[0].value)[0], "1521")
  shared_connect  = (local.shared_pe == "" || local.shared_low_host == "") ? local.shared_low : replace(local.shared_low, local.shared_low_host, "${local.shared_pe}:${local.shared_port}")
  shared_db_env = local.shared_db ? {
    SBX_SHARED_DB_ID       = oci_database_autonomous_database.shared[0].id
    SBX_SHARED_DB_NAME     = oci_database_autonomous_database.shared[0].db_name
    SBX_SHARED_DB_CONNECT  = local.shared_connect
    SBX_SHARED_DB_PASSWORD = random_password.shared_adb_admin[0].result
    SBX_SHARED_DB_WEB      = "https://${oci_apigateway_gateway.shared_db[0].hostname}"
    SBX_SHARED_DB_PRIVATE  = "1"
  } : {}
}

# The one door to the shared database: ORDS (SQL Developer Web, REST, APEX) through
# HTTPS on an Oracle hostname. ORDS is told the gateway's hostname so every redirect
# it issues (APEX sign-in, workspace home) comes back through it.
resource "oci_apigateway_gateway" "shared_db" {
  count          = local.shared_db ? 1 : 0
  compartment_id = oci_identity_compartment.sandboxes.id
  endpoint_type  = "PUBLIC"
  subnet_id      = oci_core_subnet.public.id
  display_name   = "${local.prefix}-shared-db-gw"
  freeform_tags  = local.freeform_tags

  depends_on = [oci_identity_policy.apigateway_network, time_sleep.worker_iam]
}

resource "oci_apigateway_deployment" "shared_db" {
  count          = local.shared_db ? 1 : 0
  compartment_id = oci_identity_compartment.sandboxes.id
  gateway_id     = oci_apigateway_gateway.shared_db[0].id
  path_prefix    = "/"
  display_name   = "${local.prefix}-shared-db"
  freeform_tags  = local.freeform_tags

  specification {
    dynamic "routes" {
      for_each = ["ords", "adb"]
      content {
        path    = "/${routes.value}/{p*}"
        methods = ["ANY"]
        request_policies {
          header_transformations {
            set_headers {
              items {
                name      = "X-Forwarded-Host"
                values    = [oci_apigateway_gateway.shared_db[0].hostname]
                if_exists = "OVERWRITE"
              }
              items {
                name      = "X-Forwarded-Proto"
                values    = ["https"]
                if_exists = "OVERWRITE"
              }
              items {
                name      = "Forwarded"
                values    = ["host=${oci_apigateway_gateway.shared_db[0].hostname};proto=https"]
                if_exists = "OVERWRITE"
              }
            }
          }
        }
        backend {
          type                       = "HTTP_BACKEND"
          url                        = "https://${local.shared_pe}/${routes.value}/$${request.path[p]}"
          connect_timeout_in_seconds = 10
          read_timeout_in_seconds    = 300
          send_timeout_in_seconds    = 300
        }
      }
    }
    # APEX's stylesheets, scripts and images: /i/ on the database host (without it APEX renders as raw HTML)
    routes {
      path    = "/i/{p*}"
      methods = ["GET", "HEAD"]
      backend {
        type                       = "HTTP_BACKEND"
        url                        = "https://${local.shared_pe}/i/$${request.path[p]}"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }
    routes {
      path    = "/"
      methods = ["GET"]
      backend {
        type = "HTTP_BACKEND"
        url  = "https://${local.shared_pe}/ords/_/landing"
      }
    }
  }
}

output "shared_database" {
  description = "The install's shared database (standard edition): every sandbox with a database gets a schema in it."
  value = local.shared_db ? {
    id      = oci_database_autonomous_database.shared[0].id
    db_name = oci_database_autonomous_database.shared[0].db_name
    web     = "https://${oci_apigateway_gateway.shared_db[0].hostname}"
  } : null
}
