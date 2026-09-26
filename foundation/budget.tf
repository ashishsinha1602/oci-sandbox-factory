# One budget for the whole sandbox tree, with alerts at each threshold
# plus a forecast alert when spend is on track to exceed the budget.

resource "oci_budget_budget" "sandbox" {
  provider               = oci.home
  compartment_id         = var.tenancy_ocid
  display_name           = "${var.prefix}-monthly"
  description            = "Monthly cap for the ${var.prefix} sandbox tree."
  amount                 = var.budget_amount
  reset_period           = "MONTHLY"
  processing_period_type = "MONTH"
  target_type            = "COMPARTMENT"
  targets                = [oci_identity_compartment.root.id]
  freeform_tags          = local.freeform_tags
}

resource "oci_budget_alert_rule" "actual" {
  provider = oci.home
  for_each = toset([for t in var.budget_alert_thresholds : tostring(t)])

  budget_id      = oci_budget_budget.sandbox.id
  display_name   = "${var.prefix}-actual-${each.key}pct"
  type           = "ACTUAL"
  threshold      = tonumber(each.key)
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  message        = "Sandbox spend has reached ${each.key}% of the monthly budget."
  freeform_tags  = local.freeform_tags
}

resource "oci_budget_alert_rule" "forecast" {
  provider       = oci.home
  budget_id      = oci_budget_budget.sandbox.id
  display_name   = "${var.prefix}-forecast-100pct"
  type           = "FORECAST"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.budget_alert_email
  message        = "Sandbox spend is forecast to exceed the monthly budget."
  freeform_tags  = local.freeform_tags
}
