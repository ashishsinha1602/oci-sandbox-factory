# ---------------------------------------------------------------------------
# Identity / location. Every value comes from a .tfvars file, never hardcoded.
# personal.tfvars today, liberty-dev.tfvars later.
# ---------------------------------------------------------------------------
variable "tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy (root compartment)."
}

variable "region" {
  type        = string
  description = "Home region of the tenancy, e.g. us-phoenix-1. IAM resources are always created in the home region."
}

variable "parent_compartment_ocid" {
  type        = string
  description = "Compartment under which the sandbox tree is created. Tenancy OCID on a personal account; a team compartment at Liberty."
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------
variable "prefix" {
  type        = string
  default     = "sbx"
  description = "Short name used for the compartment tree, tag namespace, VCN, budget and quotas."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.prefix))
    error_message = "prefix must be 2-15 chars, lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "environment" {
  type        = string
  default     = "personal"
  description = "Environment label stamped on every resource (personal | liberty-dev | liberty-prod)."
}

# ---------------------------------------------------------------------------
# Guardrails
# ---------------------------------------------------------------------------
variable "budget_amount" {
  type        = number
  default     = 50
  description = "Monthly budget in the tenancy currency for the whole sandbox tree."
}

variable "budget_alert_email" {
  type        = string
  description = "Recipient of budget alert emails. Comma-separate for several."
}

variable "budget_alert_thresholds" {
  type        = list(number)
  default     = [50, 80, 100]
  description = "Percent-of-budget thresholds that trigger an ACTUAL-spend alert."
}

variable "enable_quotas" {
  type        = bool
  default     = false
  description = "Create hard service quotas on the sandbox compartment. Off until the quota names are confirmed on the target tenancy."
}

variable "quota_limits" {
  type = object({
    atp_ecpu          = number
    adw_ecpu          = number
    adb_free          = number
    a1_ocpu           = number
    a1_memory_gb      = number
    oke_clusters      = number
    stream_partitions = number
  })
  default = {
    atp_ecpu          = 8
    adw_ecpu          = 8
    adb_free          = 2
    a1_ocpu           = 4
    a1_memory_gb      = 24
    oke_clusters      = 1
    stream_partitions = 5
  }
  description = "Per-service caps applied when enable_quotas = true. Defaults fit the Always Free tier."
}

# ---------------------------------------------------------------------------
# Network (one shared VCN, every sandbox stack attaches to it)
# ---------------------------------------------------------------------------
variable "vcn_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "CIDR of the shared sandbox VCN."
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.20.0.0/24"
  description = "Public subnet: load balancers, API Gateway, bastions."
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.20.10.0/24"
  description = "Private subnet: ADB private endpoints, Container Instances, OKE workers, Kafka."
}

variable "admin_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "Source CIDR allowed to reach SSH on the public subnet. Narrow this to your IP."
}

# ---------------------------------------------------------------------------
# Tagging. These become cost chargeback later.
# ---------------------------------------------------------------------------
variable "owner" {
  type        = string
  description = "Default owner tag value (your name or email)."
}

variable "team" {
  type        = string
  default     = "personal"
  description = "Default team tag value."
}

variable "app_admin_user" {
  type        = string
  default     = "SBXADMIN"
  description = "The application's first login. It signs in as the factory administrator and creates the other users."
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{2,29}$", var.app_admin_user))
    error_message = "3 to 30 characters: letters, digits and underscores, starting with a letter."
  }
}

variable "app_admin_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Password for the first login. Leave empty to have one generated; it is shown in the stack outputs."
  validation {
    condition = var.app_admin_password == "" || (length(var.app_admin_password) >= 12 && length(var.app_admin_password) <= 30
      && can(regex("[A-Z]", var.app_admin_password)) && can(regex("[a-z]", var.app_admin_password))
    && can(regex("[0-9]", var.app_admin_password)) && !can(regex("[\"' \t]", var.app_admin_password)))
    error_message = "12 to 30 characters with an upper-case letter, a lower-case letter and a digit, and no quotes or spaces."
  }
}
