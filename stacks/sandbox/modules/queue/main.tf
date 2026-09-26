terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "queues" {
  description = "OCI Queues: serverless messaging, billed per request, nothing running when idle."
  type = list(object({
    name               = string
    retention_seconds  = optional(number, 3600)
    visibility_seconds = optional(number, 30)
    dead_letter_after  = optional(number, 10)
  }))
}
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }

# OCI Queue is the point-to-point counterpart to Kafka's streams: one consumer
# takes each message, with visibility timeouts and a dead-letter count. It is
# serverless, so unlike a Streaming pool there is nothing to size.
resource "oci_queue_queue" "this" {
  for_each = { for q in var.queues : q.name => q }

  compartment_id                   = var.compartment_id
  display_name                     = "${var.name}-${each.value.name}"
  retention_in_seconds             = each.value.retention_seconds
  visibility_in_seconds            = each.value.visibility_seconds
  dead_letter_queue_delivery_count = each.value.dead_letter_after
  defined_tags                     = var.defined_tags
  freeform_tags                    = var.freeform_tags
}

output "queues" {
  value = [
    for k, q in oci_queue_queue.this : {
      name              = q.display_name
      id                = q.id
      messages_endpoint = q.messages_endpoint
    }
  ]
}
