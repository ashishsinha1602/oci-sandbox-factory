terraform {
  required_version = ">= 1.5"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

# Auth is intentionally NOT configured here.
#   Local:            ~/.oci/config [DEFAULT] profile (or OCI_CLI_PROFILE env)
#   Resource Manager: automatic (resource principal)
# Same code runs in both places with no changes.
provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  region       = var.region
}

# IAM (compartments, policies, dynamic groups, tags), budgets and quotas can
# only be written in the tenancy's HOME region. The factory itself may be
# installed in any subscribed region, so tenancy-level resources go through
# this second provider, pinned to the home region found at plan time.
data "oci_identity_region_subscriptions" "all" {
  tenancy_id = var.tenancy_ocid
}

locals {
  home_region = [for r in data.oci_identity_region_subscriptions.all.region_subscriptions : r.region_name if r.is_home_region][0]
}

provider "oci" {
  alias        = "home"
  tenancy_ocid = var.tenancy_ocid
  region       = local.home_region
}
