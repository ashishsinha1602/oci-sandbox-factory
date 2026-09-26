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
  description = "Open this, sign in with app_admin_user / app_admin_password. The first start of the workers takes a few minutes to install the application."
  value       = local.app_url
}

output "app_admin_user" {
  value = local.app_admin_user
}

output "app_admin_password" {
  value     = local.app_admin_password
  sensitive = true
}
