terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "buckets" {
  description = "Object Storage buckets for this sandbox."
  type = list(object({
    name   = string
    public = optional(bool, false)
    tier   = optional(string, "Standard")
  }))
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_id
}

# Object Storage costs pennies per GB-month and nothing while empty, so a bucket
# is cheap to hand every sandbox that wants somewhere to put files. It also does
# not touch the A1 core quota that container instances compete for.
resource "oci_objectstorage_bucket" "this" {
  for_each = { for b in var.buckets : b.name => b }

  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${var.name}-${each.value.name}"
  storage_tier   = each.value.tier
  # ObjectRead publishes every object in the bucket to the internet. It is off
  # unless a sandbox explicitly asks, because a bucket is an easy place to leave
  # something private by accident.
  access_type   = each.value.public ? "ObjectRead" : "NoPublicAccess"
  versioning    = "Disabled"
  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

variable "expiry_days" {
  description = <<-EOT
    Expire objects after this many days. 0 disables it.

    A lifecycle policy needs the Object Storage service principal to be allowed
    to manage objects in the compartment, otherwise the apply fails with
    InsufficientServicePermissions. Grant it once in the tenancy and then set
    this:

      allow service objectstorage-<region> to manage object-family
        in compartment <sandboxes compartment>

    Cleanup does not depend on it: the destroy path empties every bucket in the
    sandbox before Terraform runs, because Object Storage refuses to delete a
    bucket that still holds objects.
  EOT
  type        = number
  default     = 0
}

resource "oci_objectstorage_object_lifecycle_policy" "expire" {
  for_each = var.expiry_days > 0 ? oci_objectstorage_bucket.this : {}

  namespace = each.value.namespace
  bucket    = each.value.name

  rules {
    name        = "expire-objects"
    action      = "DELETE"
    time_amount = var.expiry_days
    time_unit   = "DAYS"
    is_enabled  = true
    target      = "objects"
  }

  rules {
    name        = "abort-incomplete-uploads"
    action      = "ABORT"
    time_amount = var.expiry_days
    time_unit   = "DAYS"
    is_enabled  = true
    target      = "multipart-uploads"
  }
}

output "namespace" {
  value = data.oci_objectstorage_namespace.ns.namespace
}

output "buckets" {
  value = [
    for k, b in oci_objectstorage_bucket.this : {
      name      = b.name
      namespace = b.namespace
      public    = b.access_type != "NoPublicAccess"
    }
  ]
}
