terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "enable_ai" {
  description = "Switch on the platform's AI features. Off by default: it needs a vector database attached."
  type        = bool
  default     = false
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }

# Oracle AI Data Platform: one lakehouse service (managed Spark, an
# Iceberg-based catalog, notebooks, AI) - the counterpart to Databricks or to
# Glue + Athena + SageMaker together. This creates the platform instance with
# its default workspace; compute clusters are sized and started inside the
# platform's own UI. Like everything else in the sandbox it is destroyed at
# the sandbox's expiry.
resource "oci_ai_data_platform_ai_data_platform" "this" {
  compartment_id         = var.compartment_id
  display_name           = "${var.name}-aidp"
  default_workspace_name = replace("${var.name}-workspace", "-", "_")
  is_enable_ai_feature   = var.enable_ai
  defined_tags           = var.defined_tags
  freeform_tags          = var.freeform_tags

  timeouts {
    create = "90m"
    delete = "60m"
  }
}

output "aidp" {
  value = {
    id                  = oci_ai_data_platform_ai_data_platform.this.id
    display_name        = oci_ai_data_platform_ai_data_platform.this.display_name
    state               = oci_ai_data_platform_ai_data_platform.this.state
    workspace           = oci_ai_data_platform_ai_data_platform.this.default_workspace_name
    web_socket_endpoint = oci_ai_data_platform_ai_data_platform.this.web_socket_endpoint
    alias_key           = oci_ai_data_platform_ai_data_platform.this.alias_key
  }
}
