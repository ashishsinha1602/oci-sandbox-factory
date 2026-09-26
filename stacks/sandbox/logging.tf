# Logs for everything in the sandbox that OCI Logging can collect: each
# function call (invoke), and every request through the sandbox's HTTPS
# gateways (access and execution). One log group per sandbox, 30 days, gone
# with the sandbox. Data Flow runs keep their logs in the sandbox bucket, and
# container output is on the card through the worker.
locals {
  fn_gateway  = length(var.functions) > 0 && var.functions_gateway
  app_gateway = var.enable_app && var.app_gateway
  log_sources = merge(
    length(var.functions) > 0 ? { "functions-invoke" = { service = "functions", category = "invoke" } } : {},
    local.fn_gateway ? {
      "fn-gateway-access"    = { service = "apigateway", category = "access" }
      "fn-gateway-execution" = { service = "apigateway", category = "execution" }
    } : {},
    local.app_gateway ? {
      "app-gateway-access"    = { service = "apigateway", category = "access" }
      "app-gateway-execution" = { service = "apigateway", category = "execution" }
    } : {},
  )
  log_resource = {
    "functions-invoke"      = try(module.functions[0].application_id, "")
    "fn-gateway-access"     = try(module.functions[0].deployment_id, "")
    "fn-gateway-execution"  = try(module.functions[0].deployment_id, "")
    "app-gateway-access"    = try(module.app[0].deployment_id, "")
    "app-gateway-execution" = try(module.app[0].deployment_id, "")
  }
}

resource "oci_logging_log_group" "sandbox" {
  count          = length(local.log_sources) > 0 ? 1 : 0
  compartment_id = local.compartment_id
  display_name   = "${local.name}-logs"
  description    = "Logs of sandbox ${var.sandbox_id}"
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags
}

resource "oci_logging_log" "service" {
  for_each = local.log_sources

  display_name       = "${local.name}-${each.key}"
  log_group_id       = oci_logging_log_group.sandbox[0].id
  log_type           = "SERVICE"
  is_enabled         = true
  retention_duration = 30
  defined_tags       = local.defined_tags
  freeform_tags      = local.freeform_tags

  configuration {
    compartment_id = local.compartment_id
    source {
      source_type = "OCISERVICE"
      service     = each.value.service
      category    = each.value.category
      resource    = local.log_resource[each.key]
    }
  }
}

output "logs" {
  value = length(local.log_sources) > 0 ? {
    log_group_id = oci_logging_log_group.sandbox[0].id
    logs         = keys(local.log_sources)
    console_url  = "https://cloud.oracle.com/logging/log-groups/${oci_logging_log_group.sandbox[0].id}?region=${var.region}"
    search_url   = "https://cloud.oracle.com/logging/search?region=${var.region}"
  } : null
}
