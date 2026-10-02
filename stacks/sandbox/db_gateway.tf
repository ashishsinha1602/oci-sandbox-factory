# A sandbox with a private database and no app has nothing a browser can reach: its
# APEX, SQL Developer Web and REST live on the private endpoint. This gateway is the
# way in for such a sandbox, the same /ords/* proxy the app module gives a sandbox
# that has an app. The database stays private. ORDS is told the gateway's hostname
# so every redirect it issues (APEX sign-in, workspace home) comes back through it.

locals {
  db_gateway = var.enable_adb && !var.enable_app && var.app_gateway && var.adb_tier == "paid" && !var.adb_public
}

resource "oci_apigateway_gateway" "db" {
  count          = local.db_gateway ? 1 : 0
  compartment_id = local.compartment_id
  endpoint_type  = "PUBLIC"
  subnet_id      = var.public_subnet_id
  display_name   = "${local.name}-db-gw"
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

resource "oci_apigateway_deployment" "db" {
  count          = local.db_gateway ? 1 : 0
  compartment_id = local.compartment_id
  gateway_id     = oci_apigateway_gateway.db[0].id
  path_prefix    = "/"
  display_name   = "${local.name}-db"
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  specification {
    routes {
      path    = "/ords/{p*}"
      methods = ["ANY"]
      request_policies {
        header_transformations {
          set_headers {
            items {
              name      = "X-Forwarded-Host"
              values    = [oci_apigateway_gateway.db[0].hostname]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Forwarded-Proto"
              values    = ["https"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "Forwarded"
              values    = ["host=${oci_apigateway_gateway.db[0].hostname};proto=https"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
      backend {
        type                       = "HTTP_BACKEND"
        url                        = "https://${module.adb[0].private_fqdn}/ords/$${request.path[p]}"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }
    # APEX signs in through the database's own /adb/auth pages (verified 2026-09-30)
    routes {
      path    = "/adb/{p*}"
      methods = ["ANY"]
      request_policies {
        header_transformations {
          set_headers {
            items {
              name      = "X-Forwarded-Host"
              values    = [oci_apigateway_gateway.db[0].hostname]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "X-Forwarded-Proto"
              values    = ["https"]
              if_exists = "OVERWRITE"
            }
            items {
              name      = "Forwarded"
              values    = ["host=${oci_apigateway_gateway.db[0].hostname};proto=https"]
              if_exists = "OVERWRITE"
            }
          }
        }
      }
      backend {
        type                       = "HTTP_BACKEND"
        url                        = "https://${module.adb[0].private_fqdn}/adb/$${request.path[p]}"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }
    # APEX's stylesheets, scripts and images: /i/ on the database host (without it APEX renders as raw HTML)
    routes {
      path    = "/i/{p*}"
      methods = ["GET", "HEAD"]
      backend {
        type                       = "HTTP_BACKEND"
        url                        = "https://${module.adb[0].private_fqdn}/i/$${request.path[p]}"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }
    routes {
      # the gateway's root: straight to Database Actions
      path    = "/"
      methods = ["GET"]
      backend {
        type = "HTTP_BACKEND"
        url  = "https://${module.adb[0].private_fqdn}/ords/_/landing"
      }
    }
  }
}

output "db_gateway_url" {
  value = local.db_gateway ? "https://${oci_apigateway_gateway.db[0].hostname}" : null
}
