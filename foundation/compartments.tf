# Compartment tree
#   <parent>
#   └── sbx                 budget + quotas scope
#       ├── sbx-control     shared VCN, Resource Manager stacks, Vault, logging
#       └── sbx-sandboxes   one sub-compartment per sandbox (created by the factory)

resource "oci_identity_compartment" "root" {
  provider       = oci.home
  compartment_id = var.parent_compartment_ocid
  name           = var.prefix
  description    = "Sandbox factory root. Budget and quotas apply here."
  enable_delete  = true
  freeform_tags  = local.freeform_tags
}

resource "oci_identity_compartment" "control" {
  provider       = oci.home
  compartment_id = oci_identity_compartment.root.id
  name           = "${var.prefix}-control"
  description    = "Shared infrastructure: VCN, stacks, secrets, logs."
  enable_delete  = true
  freeform_tags  = local.freeform_tags
}

resource "oci_identity_compartment" "sandboxes" {
  provider       = oci.home
  compartment_id = oci_identity_compartment.root.id
  name           = "${var.prefix}-sandboxes"
  description    = "Parent of every user sandbox compartment."
  enable_delete  = true
  freeform_tags  = local.freeform_tags
}
