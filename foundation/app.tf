# What the installer needs to start using the factory: the application URL and
# a first login. The workers create the application on their first start
# (factory/bootstrap.py) with this admin password, so it works straight away.

resource "random_password" "app_admin" {
  length           = 20
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
  override_special = "#_-"
}

locals {
  # the installer's own choice from the form, or a generated one
  app_admin_user     = upper(var.app_admin_user)
  app_admin_password = var.app_admin_password != "" ? var.app_admin_password : random_password.app_admin.result
  app_url            = var.enable_control_adb ? try(replace(oci_database_autonomous_database.control[0].connection_urls[0].apex_url, "/ords/apex", "/ords/r/sbx/sandbox-factory/"), "") : ""
}

output "app_url" {
  description = "The application. It appears at this URL a few minutes after this apply finishes (up to 10 on the Free Tier edition): the worker installs it on its first start. Until then the URL shows 404; that is normal. Sign in with app_admin_user / app_admin_password."
  value       = local.app_url
}

output "next_step" {
  description = "What to do once this apply is green."
  value       = "Open status_url: it shows the install progress and opens the application by itself when it is ready (a few minutes; up to 10 on the Free Tier edition). If it shows 404 for the first minutes, the worker has not started yet; wait and reload. Then sign in with app_admin_user / app_admin_password."
}

output "status_url" {
  description = "Open this first. Install progress from the worker's first minute on; it refreshes itself and opens the application when ready (JSON for scripts). 404 only until the worker's first start."
  value       = var.enable_control_adb ? try(replace(oci_database_autonomous_database.control[0].connection_urls[0].apex_url, "/ords/apex", "/ords/admin/status/"), "") : ""
}

output "app_admin_user" {
  value = local.app_admin_user
}

output "app_admin_password" {
  value     = local.app_admin_password
  sensitive = true
}
