# The install's name prefix: the one typed on the form, or a generated one when none arrived.
resource "random_string" "prefix" {
  count   = var.prefix == "" ? 1 : 0
  length  = 4
  upper   = false
  special = false
}

locals {
  prefix = var.prefix != "" ? var.prefix : "sbx${random_string.prefix[0].result}"

  freeform_tags = {
    environment = var.environment
    managed_by  = "terraform"
    stack       = "${local.prefix}-foundation"
    team        = var.team
    owner       = var.owner
  }
}
