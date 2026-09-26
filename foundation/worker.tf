# The factory's workers: Container Instances in <prefix>-control that poll the
# request queue, build app images with kaniko and drive Resource Manager. They
# act as their own principal (resource principal, no key file). On first start
# a worker makes the control database ready by itself (factory/bootstrap.py):
# schema, the APEX application, the assistant's prompts and the tenancy profile.

variable "enable_worker" {
  type        = bool
  default     = true
  description = "Run the workers. Off only for a laptop-driven development install."
}

variable "worker_count" {
  type        = number
  default     = 3
  description = "Workers polling the queue; each builds one sandbox at a time. Every worker is 1 OCPU / 4 GB (E4)."
  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 10
    error_message = "worker_count must be 1-10."
  }
}

variable "worker_image" {
  type        = string
  default     = "phx.ocir.io/ax3sbu0rnjhx/sandbox-factory/worker:release"
  description = "The worker image. The default is the published release (a public repository any tenancy and region can pull). Override with your own build of factory/Dockerfile."
}

variable "current_user_ocid" {
  type        = string
  default     = ""
  description = "Filled in by Resource Manager: the user running the install. Used to create the registry token below."
}

variable "ocir_user" {
  type        = string
  default     = ""
  description = "Registry login (without the namespace) for pushing the apps users build. Empty = the installing user."
}

variable "ocir_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Auth token for that login. Empty = create one for the installing user (a user may hold at most two)."
}

locals {
  make_token   = var.enable_worker && var.ocir_token == "" && var.current_user_ocid != ""
  ocir_user    = var.ocir_user != "" ? var.ocir_user : (local.make_token ? data.oci_identity_user.installer[0].name : "")
  ocir_token   = var.ocir_token != "" ? var.ocir_token : (local.make_token ? oci_identity_auth_token.ocir[0].token : "")
  worker_names = [for n in range(var.worker_count) : n == 0 ? "${var.prefix}-worker" : "${var.prefix}-worker-${n + 1}"]
}

data "oci_identity_user" "installer" {
  count    = local.make_token ? 1 : 0
  provider = oci.home
  user_id  = var.current_user_ocid
}

resource "oci_identity_auth_token" "ocir" {
  count       = local.make_token ? 1 : 0
  provider    = oci.home
  user_id     = var.current_user_ocid
  description = "${var.prefix} sandbox factory: workers push the images users build"
}

resource "oci_identity_dynamic_group" "worker" {
  count          = var.enable_worker ? 1 : 0
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-worker-dg"
  description    = "Sandbox factory workers, build and test containers in ${var.prefix}-control."
  matching_rule  = "ALL {resource.type = 'computecontainerinstance', resource.compartment.id = '${oci_identity_compartment.control.id}'}"
  freeform_tags  = local.freeform_tags
}

resource "oci_identity_policy" "worker" {
  count          = var.enable_worker ? 1 : 0
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-worker-policy"
  description    = "What the sandbox factory workers may do."
  freeform_tags  = local.freeform_tags
  statements = [
    # everything it builds for people lives in the sandboxes compartment
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to manage all-resources in compartment id ${oci_identity_compartment.sandboxes.id}",
    # one Resource Manager stack per sandbox, kept in control
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to manage orm-stacks in compartment id ${oci_identity_compartment.control.id}",
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to manage orm-jobs in compartment id ${oci_identity_compartment.control.id}",
    # image repositories for the apps users build, and kaniko build containers
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to manage repos in compartment id ${oci_identity_compartment.control.id}",
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to manage compute-container-family in compartment id ${oci_identity_compartment.control.id}",
    # a sandbox's NSGs and public gateway IPs attach to the VCN in control
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to manage virtual-network-family in compartment id ${oci_identity_compartment.control.id}",
    # bucket clean-up before destroy, test reports, demo recordings
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to manage object-family in compartment id ${oci_identity_compartment.control.id}",
    # per-sandbox secrets (the Kafka superuser) under the shared vault
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to use vaults in compartment id ${oci_identity_compartment.control.id}",
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to use keys in compartment id ${oci_identity_compartment.control.id}",
    # the tenancy profile probes which chat models answer here
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to use generative-ai-family in compartment id ${oci_identity_compartment.control.id}",
    # region key, namespace, limits (gateway / catalog fallbacks), public images, tags
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to read objectstorage-namespaces in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to read limits in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to read repos in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to inspect compartments in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to inspect tenancies in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.worker[0].name} to use tag-namespaces in tenancy",
  ]
}

data "oci_identity_availability_domains" "worker" {
  count          = var.enable_worker ? 1 : 0
  compartment_id = var.tenancy_ocid
}

resource "oci_container_instances_container_instance" "worker" {
  for_each                 = var.enable_worker ? toset(local.worker_names) : toset([])
  compartment_id           = oci_identity_compartment.control.id
  availability_domain      = data.oci_identity_availability_domains.worker[0].availability_domains[0].name
  display_name             = each.key
  shape                    = "CI.Standard.E4.Flex" # x86: the release image is built for amd64
  container_restart_policy = "ALWAYS"
  freeform_tags            = merge(local.freeform_tags, { role = "worker" })

  shape_config {
    ocpus         = 1
    memory_in_gbs = 4
  }

  vnics {
    subnet_id             = oci_core_subnet.private.id
    display_name          = each.key
    is_public_ip_assigned = false
  }

  containers {
    display_name = "worker"
    image_url    = var.worker_image
    environment_variables = {
      WORKER_NAME = each.key
      SBX_PREFIX  = var.prefix
      # the shipped starter images live next to the worker image (…/sandbox-factory/)
      SBX_RELEASE_REGISTRY = regex("^(.*/)[^/]+$", split(":", var.worker_image)[0])[0]
      SBX_WORKER_KIND      = "oci"
      SBX_BUILD_MODE       = "kaniko"
      SBX_CONTROL_CONNECT  = oci_database_autonomous_database.control[0].connection_strings[0].all_connection_strings["LOW"]
      SBX_ADMIN_PASSWORD   = random_password.control_adb_admin[0].result
      # the first login (app.tf) and who owns what the install creates
      SBX_APP_ADMIN_USER     = local.app_admin_user
      SBX_APP_ADMIN_PASSWORD = local.app_admin_password
      SBX_OWNER              = var.owner
      SBX_APP_URL            = local.app_url
      SBX_FOUNDATION = jsonencode({
        compartments = { root = oci_identity_compartment.root.id, control = oci_identity_compartment.control.id, sandboxes = oci_identity_compartment.sandboxes.id }
        network = {
          vcn_id         = oci_core_vcn.sandbox.id, public_subnet_id = oci_core_subnet.public.id, private_subnet_id = oci_core_subnet.private.id
          nat_gateway_id = oci_core_nat_gateway.nat.id, service_gateway_id = oci_core_service_gateway.sgw.id
        }
        tag_namespace = oci_identity_tag_namespace.sandbox.name
      })
      OCIR_USER  = local.ocir_user
      OCIR_TOKEN = local.ocir_token
    }
  }

  # IAM is eventually consistent: a worker that starts before its policy lands
  # spends its first minutes on 404s from Resource Manager.
  depends_on = [time_sleep.worker_iam]
}

resource "time_sleep" "worker_iam" {
  count           = var.enable_worker ? 1 : 0
  depends_on      = [oci_identity_policy.worker]
  create_duration = "90s"
}

output "workers" {
  value = [for k, w in oci_container_instances_container_instance.worker : { name = k, id = w.id, state = w.state }]
}
