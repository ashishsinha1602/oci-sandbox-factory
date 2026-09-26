# Oracle AI Data Platform: the grants the service needs to create an instance
# and its default workspace in the sandboxes compartment (from Oracle's AIDP IAM
# guide). Without them a sandbox with enable_aidp fails with 404 "default domain
# type". Turn off when the tenancy should never run AIDP.

variable "enable_aidp" {
  type        = bool
  default     = true
  description = "Grant Oracle AI Data Platform what it needs, so sandboxes may include an AIDP instance."
}

resource "oci_identity_policy" "aidp" {
  provider       = oci.home
  count          = var.enable_aidp ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-aidp"
  description    = "Oracle AI Data Platform instances created in ${var.prefix} sandboxes."
  freeform_tags  = local.freeform_tags
  statements = [
    "allow any-user to {AUTHENTICATION_INSPECT, DOMAIN_INSPECT, DOMAIN_READ, DYNAMIC_GROUP_INSPECT, GROUP_INSPECT, GROUP_MEMBERSHIP_INSPECT, USER_INSPECT, USER_READ} in tenancy where all {request.principal.type='aidataplatform'}",
    "allow any-user to manage log-groups in compartment id ${oci_identity_compartment.sandboxes.id} where ALL {request.principal.type='aidataplatform'}",
    "allow any-user to read log-content in compartment id ${oci_identity_compartment.sandboxes.id} where ALL {request.principal.type='aidataplatform'}",
    "allow any-user to use metrics in compartment id ${oci_identity_compartment.sandboxes.id} where ALL {request.principal.type='aidataplatform', target.metrics.namespace='oracle_aidataplatform'}",
    "allow any-user to manage buckets in tenancy where all {request.principal.type='aidataplatform', any {request.permission = 'BUCKET_CREATE', request.permission = 'BUCKET_INSPECT', request.permission = 'BUCKET_READ', request.permission = 'BUCKET_UPDATE'}}",
    "allow any-user to {TAG_NAMESPACE_USE} in tenancy where all {request.principal.type = 'aidataplatform'}",
    "allow any-user to manage buckets in tenancy where all {request.principal.id=target.resource.tag.orcl-aidp.governingAidpId, any {request.permission = 'BUCKET_DELETE', request.permission = 'PAR_MANAGE', request.permission = 'RETENTION_RULE_LOCK', request.permission = 'RETENTION_RULE_MANAGE'}}",
    "allow any-user to read objectstorage-namespaces in tenancy where all {request.principal.type='aidataplatform', any {request.permission = 'OBJECTSTORAGE_NAMESPACE_READ'}}",
    "allow any-user to manage objects in tenancy where all {request.principal.id=target.bucket.system-tag.orcl-aidp.governingAidpId}",
    "allow any-user to use generative-ai-family in tenancy where all {request.principal.type='aidataplatform'}",
    "allow any-user to use generative-ai-family in tenancy where all {request.principal.type='datalake'}",
  ]
}
