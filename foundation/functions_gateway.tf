# Every OCI Function a sandbox creates gets a plain HTTPS URL through an API
# gateway in the same sandbox. The gateway calls the function as itself, so
# it needs this one grant. Created in the tenancy root, like the other
# service-principal policies here.
resource "oci_identity_policy" "apigateway_functions" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-apigateway-functions"
  description    = "Sandbox API gateways may invoke the OCI Functions in sbx-sandboxes, so every function gets a plain HTTPS URL."
  statements = [
    "allow any-user to use functions-family in compartment id ${oci_identity_compartment.sandboxes.id} where ALL {request.principal.type = 'ApiGateway', request.resource.compartment.id = '${oci_identity_compartment.sandboxes.id}'}",
  ]
}

# The Functions service pulls function images from the registry as itself.
resource "oci_identity_policy" "functions_registry" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-functions-registry"
  description    = "OCI Functions may pull the function images the factory builds into the registry."
  statements = [
    "allow service faas to read repos in tenancy",
    "allow service faas to use apm-domains in tenancy",
  ]
}
