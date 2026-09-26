# Every later stack (ADB, Kafka, app, OKE) reads these instead of guessing.

output "compartments" {
  description = "OCIDs of the sandbox compartment tree."
  value = {
    root      = oci_identity_compartment.root.id
    control   = oci_identity_compartment.control.id
    sandboxes = oci_identity_compartment.sandboxes.id
  }
}

output "network" {
  description = "Shared VCN and subnets for sandbox stacks."
  value = {
    vcn_id             = oci_core_vcn.sandbox.id
    public_subnet_id   = oci_core_subnet.public.id
    private_subnet_id  = oci_core_subnet.private.id
    nat_gateway_id     = oci_core_nat_gateway.nat.id
    service_gateway_id = oci_core_service_gateway.sgw.id
  }
}

output "tag_namespace" {
  description = "Tag namespace name; sandbox stacks write <namespace>.owner / sandbox_id / team / expires."
  value       = oci_identity_tag_namespace.sandbox.name
}

output "budget_id" {
  value = oci_budget_budget.sandbox.id
}
