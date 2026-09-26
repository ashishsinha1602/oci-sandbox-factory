# Defined tags. Every sandbox resource carries these four; they drive
# auto-destroy (expires) and chargeback (owner, team, sandbox_id).

resource "oci_identity_tag_namespace" "sandbox" {
  provider       = oci.home
  compartment_id = oci_identity_compartment.root.id
  name           = var.prefix
  description    = "Sandbox factory tags."
  is_retired     = false
  freeform_tags  = local.freeform_tags
}

locals {
  tag_keys = {
    owner      = "Who requested the sandbox (email or principal name)."
    sandbox_id = "Unique id of the sandbox this resource belongs to."
    team       = "Team charged for the resource."
    expires    = "UTC date (YYYY-MM-DD) after which the auto-destroy job removes the sandbox."
  }
}

resource "oci_identity_tag" "keys" {
  provider = oci.home
  for_each = local.tag_keys

  tag_namespace_id = oci_identity_tag_namespace.sandbox.id
  name             = each.key
  description      = each.value
  is_cost_tracking = contains(["owner", "team", "sandbox_id"], each.key)
  is_retired       = false
}

# Tag default: anything created under sbx-sandboxes is stamped with the
# creating principal as owner, even if a stack forgets to tag it.
resource "oci_identity_tag_default" "owner" {
  provider          = oci.home
  compartment_id    = oci_identity_compartment.sandboxes.id
  tag_definition_id = oci_identity_tag.keys["owner"].id
  value             = "$${iam.principal.name}"
  is_required       = false
}
