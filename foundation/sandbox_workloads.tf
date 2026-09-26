# Identity for code that runs INSIDE a sandbox: the sandbox databases, the
# container instances (Airflow, apps) and functions. Matched by compartment,
# so every sandbox gets it without per-sandbox IAM. These grants are what let
# a sandbox call Generative AI, run Data Flow, harvest the catalog and read
# its buckets without any key on disk.
resource "oci_identity_dynamic_group" "sandbox" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-sandbox-adb-dg"
  description    = "Every resource principal inside sbx-sandboxes: the sandbox databases, and functions. Lets them call Generative AI without keys."
  matching_rule  = "Any {resource.compartment.id = '${oci_identity_compartment.sandboxes.id}'}"
}

resource "oci_identity_policy" "sandbox_genai" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-sandbox-adb-genai"
  description    = "Sandbox databases and containers may use Generative AI (knowledge-base answers, Select AI)."
  statements     = ["allow dynamic-group ${oci_identity_dynamic_group.sandbox.name} to use generative-ai-family in tenancy"]
}

resource "oci_identity_policy" "sandbox_workloads" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-sandbox-workloads"
  description    = "Code running inside a sandbox (Airflow, apps, functions) may drive the sandbox data services; Data Flow runs and Data Catalog may read the sandbox buckets."
  statements = [
    "allow dynamic-group ${oci_identity_dynamic_group.sandbox.name} to manage object-family in compartment id ${oci_identity_compartment.sandboxes.id}",
    "allow dynamic-group ${oci_identity_dynamic_group.sandbox.name} to manage dataflow-family in compartment id ${oci_identity_compartment.sandboxes.id}",
    "allow dynamic-group ${oci_identity_dynamic_group.sandbox.name} to manage data-catalog-family in compartment id ${oci_identity_compartment.sandboxes.id}",
    "allow dynamic-group ${oci_identity_dynamic_group.sandbox.name} to read compartments in tenancy",
    "allow any-user to manage object-family in compartment id ${oci_identity_compartment.sandboxes.id} where ALL {request.principal.type = 'dataflowrun', request.principal.compartment.id = '${oci_identity_compartment.sandboxes.id}'}",
    "allow any-user to read object-family in compartment id ${oci_identity_compartment.sandboxes.id} where ALL {request.principal.type = 'datacatalog', request.principal.compartment.id = '${oci_identity_compartment.sandboxes.id}'}",
    "allow any-user to read buckets in compartment id ${oci_identity_compartment.sandboxes.id} where ALL {request.principal.type = 'datacatalog', request.principal.compartment.id = '${oci_identity_compartment.sandboxes.id}'}",
  ]
}

# Service principals: the API Gateway attaches to the shared VCN; Data Flow
# reads job scripts and writes logs in the sandbox buckets.
resource "oci_identity_policy" "apigateway_network" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-apigateway-network"
  description    = "API Gateway may attach to the shared VCN."
  statements     = ["allow service apigateway to use virtual-network-family in tenancy"]
}

resource "oci_identity_policy" "dataflow" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-dataflow"
  description    = "Data Flow may read scripts and write logs in the control and sandbox buckets."
  statements = [
    "allow service dataflow to read buckets in compartment id ${oci_identity_compartment.control.id}",
    "allow service dataflow to read objects in compartment id ${oci_identity_compartment.control.id}",
    "allow service dataflow to read buckets in compartment id ${oci_identity_compartment.sandboxes.id}",
    "allow service dataflow to manage objects in compartment id ${oci_identity_compartment.sandboxes.id}",
  ]
}
