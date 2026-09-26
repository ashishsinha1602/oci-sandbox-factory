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

# No auth here. Locally: ~/.oci/config. In Resource Manager: automatic.
provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  region       = var.region
}

# A per-sandbox compartment (per_sandbox_compartment = true) is IAM, which can
# only be written in the tenancy's home region; the sandbox itself may live in
# any subscribed region.
data "oci_identity_region_subscriptions" "all" {
  tenancy_id = var.tenancy_ocid
}

provider "oci" {
  alias        = "home"
  tenancy_ocid = var.tenancy_ocid
  region       = [for r in data.oci_identity_region_subscriptions.all.region_subscriptions : r.region_name if r.is_home_region][0]
}
