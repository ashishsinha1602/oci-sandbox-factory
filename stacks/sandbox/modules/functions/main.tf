terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "subnet_id" { type = string }
variable "gateway" {
  description = "Create the gateway that gives each function a URL. Off when the region has no gateway left."
  type        = bool
  default     = true
}
variable "public_subnet_id" {
  description = "Where the gateway that fronts the functions lives."
  type        = string
}
variable "functions" {
  description = "Functions to create. Each image must already exist in a registry the tenancy can pull from."
  type = list(object({
    name        = string
    image       = string
    memory_mbs  = optional(number, 256)
    timeout_sec = optional(number, 30)
    env         = optional(map(string), {})
  }))
}
variable "injected_env" {
  description = "Connection details for the rest of the sandbox, merged into every function."
  type        = map(string)
  default     = {}
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }

# OCI Functions: serverless containers, billed per invocation rather than per
# hour. They cost nothing while idle, which is why they do not count against the
# A1 core quota the way a container instance does.
resource "oci_functions_application" "this" {
  compartment_id = var.compartment_id
  display_name   = "${var.name}-fn"
  subnet_ids     = [var.subnet_id]
  shape          = "GENERIC_ARM"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags
}

resource "oci_functions_function" "this" {
  for_each = { for f in var.functions : f.name => f }

  application_id     = oci_functions_application.this.id
  display_name       = each.value.name
  image              = each.value.image
  memory_in_mbs      = each.value.memory_mbs
  timeout_in_seconds = each.value.timeout_sec
  config             = merge(var.injected_env, each.value.env)
  defined_tags       = var.defined_tags
  freeform_tags      = var.freeform_tags
}

# Invoking a function directly needs a signed OCI request, which is not
# something a user can paste into a browser or curl. A gateway in front of the
# application turns every function into a plain HTTPS URL, /<function name>,
# with nothing to sign. The gateway is allowed to call the functions by the
# tenancy policy sbx-apigateway-functions.
resource "oci_apigateway_gateway" "fn" {
  count          = var.gateway ? 1 : 0
  compartment_id = var.compartment_id
  endpoint_type  = "PUBLIC"
  subnet_id      = var.public_subnet_id
  display_name   = "${var.name}-fn-gw"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags
}

resource "oci_apigateway_deployment" "fn" {
  count          = var.gateway ? 1 : 0
  compartment_id = var.compartment_id
  gateway_id     = oci_apigateway_gateway.fn[0].id
  path_prefix    = "/"
  display_name   = "${var.name}-fn"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags

  specification {
    request_policies {
      cors {
        allowed_origins = ["*"]
        allowed_methods = ["*"]
        allowed_headers = ["*"]
      }
    }
    dynamic "routes" {
      for_each = oci_functions_function.this
      content {
        path    = "/${routes.key}"
        methods = ["ANY"]
        backend {
          type        = "ORACLE_FUNCTIONS_BACKEND"
          function_id = routes.value.id
        }
      }
    }
  }
}

output "application_id" {
  value = oci_functions_application.this.id
}

output "invoke_endpoint" {
  value = oci_functions_application.this.id
}

output "functions" {
  value = [
    for k, f in oci_functions_function.this : {
      name            = k
      id              = f.id
      invoke_endpoint = f.invoke_endpoint
      url             = var.gateway ? "https://${oci_apigateway_gateway.fn[0].hostname}/${k}" : null
    }
  ]
}

output "deployment_id" {
  value = try(oci_apigateway_deployment.fn[0].id, null)
}
