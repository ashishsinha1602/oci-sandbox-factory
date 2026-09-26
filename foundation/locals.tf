locals {
  freeform_tags = {
    environment = var.environment
    managed_by  = "terraform"
    stack       = "${var.prefix}-foundation"
    team        = var.team
    owner       = var.owner
  }
}
