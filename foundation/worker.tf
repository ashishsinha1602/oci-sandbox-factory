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

# OCI allows a user two auth tokens. Check before creating one, so a user who
# already has two gets a plain message at plan time instead of a failed apply.
data "oci_identity_auth_tokens" "installer" {
  count    = local.make_token ? 1 : 0
  provider = oci.home
  user_id  = var.current_user_ocid
}

resource "oci_identity_auth_token" "ocir" {
  count       = local.make_token ? 1 : 0
  provider    = oci.home
  user_id     = var.current_user_ocid
  description = "${var.prefix} sandbox factory: workers push the images users build"

  lifecycle {
    precondition {
      # room for a new token, or this install's token already exists (a re-apply)
      condition = (length([for t in data.oci_identity_auth_tokens.installer[0].tokens : t if t.state == "ACTIVE"]) < 2
      || contains([for t in data.oci_identity_auth_tokens.installer[0].tokens : t.description], "${var.prefix} sandbox factory: workers push the images users build"))
      error_message = "You already have 2 auth tokens, the most OCI allows. Either delete one (Profile > Auth tokens) and run Apply again, or paste an existing token in 'Registry auth token' on the form."
    }
  }
}

resource "oci_identity_dynamic_group" "worker" {
  count          = var.enable_worker ? 1 : 0
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-worker-dg"
  description    = "Sandbox factory workers, build and test containers in ${var.prefix}-control."
  # Standard: the container instances in <prefix>-control (the released rule, unchanged).
  # Free Tier: the worker VM in <prefix>-control. One flat rule per edition: a nested
  # ANY {ALL {...}, ALL {...}} is accepted by IAM but never matched the container
  # instances (clean standard install sbx10, 2026-09-29: every worker call refused).
  matching_rule = local.free ? "ALL {instance.compartment.id = '${oci_identity_compartment.control.id}'}" : "ALL {resource.type = 'computecontainerinstance', resource.compartment.id = '${oci_identity_compartment.control.id}'}"
  freeform_tags = local.freeform_tags
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

locals {
  free   = var.edition == "free"
  use_ci = var.enable_worker && !local.free # standard: container instances
  use_vm = var.enable_worker && local.free  # Free Tier: one Always Free VM running the same image under podman
  # on the Arm VM (2 OCPU / 12 GB of the free 4 / 24) the sandboxes' containers run beside the worker
  free_apps = local.free && can(regex("A1", var.worker_shape))

  # One environment for both shapes, so the worker behaves the same wherever it runs.
  worker_env_base = {
    SBX_PREFIX    = var.prefix
    SBX_EDITION   = var.edition
    SBX_FREE_APPS = local.free_apps ? "1" : "0"
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
    SBX_GEMINI_API_KEY     = var.gemini_api_key
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
  # the standard edition's shared database (shared_db.tf); the Free Tier edition uses the control database
  worker_env = merge(local.worker_env_base, local.shared_db_env)
}

data "oci_identity_availability_domains" "worker" {
  count          = var.enable_worker ? 1 : 0
  compartment_id = var.tenancy_ocid
}

resource "oci_container_instances_container_instance" "worker" {
  for_each                 = local.use_ci ? toset(local.worker_names) : toset([])
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
    display_name          = "worker"
    image_url             = var.worker_image
    environment_variables = merge(local.worker_env, { WORKER_NAME = each.key })
  }

  # IAM is eventually consistent: a worker that starts before its policy lands
  # spends its first minutes on 404s from Resource Manager.
  depends_on = [time_sleep.worker_iam]
}

# ---- Free Tier edition: the worker on an Always Free VM ----------------------
# Container Instances are not part of Always Free, so a Free Tier tenancy runs
# the very same worker image under podman on one Always Free VM in the private
# subnet (no public IP; OCIR and the OCI APIs are reached through the NAT and
# service gateways). systemd restarts it, and every start pulls the image again,
# so a reboot picks up a new release. The worker image is published for both
# x86 and Arm, so either Always Free shape runs it.
# Always Free shapes are offered in ONE availability domain per tenancy (Oracle
# picks it), so the VM goes wherever the shape exists, not blindly in AD-1.
data "oci_core_shapes" "worker" {
  for_each            = local.use_vm ? toset([for ad in data.oci_identity_availability_domains.worker[0].availability_domains : ad.name]) : toset([])
  compartment_id      = var.tenancy_ocid
  availability_domain = each.key
  filter {
    name   = "name"
    values = [var.worker_shape]
  }
}

locals {
  worker_ads = [for ad, d in data.oci_core_shapes.worker : ad if length(d.shapes) > 0]
}

data "oci_core_images" "worker" {
  count                    = local.use_vm ? 1 : 0
  compartment_id           = var.tenancy_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.worker_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  worker_env_file   = join("\n", [for k, v in merge(local.worker_env, { WORKER_NAME = "${var.prefix}-worker" }) : "${k}=${v}"])
  worker_cloud_init = <<-EOT
    #cloud-config
    write_files:
      - path: /etc/sbx/worker.env
        permissions: '0600'
        content: |
          ${indent(10, local.worker_env_file)}
      - path: /etc/systemd/system/sbx-worker.service
        permissions: '0644'
        content: |
          [Unit]
          Description=Sandbox Factory worker
          After=network-online.target
          Wants=network-online.target

          [Service]
          Restart=always
          RestartSec=20
          TimeoutStartSec=0
          ExecStartPre=-/usr/bin/podman rm -f sbx-worker
          ExecStart=/usr/bin/podman run --rm --name sbx-worker --pull=always --env-file /etc/sbx/worker.env --log-driver=journald -v /run/podman/podman.sock:/run/podman/podman.sock --security-opt label=disable ${var.worker_image}

          [Install]
          WantedBy=multi-user.target
    runcmd:
      # 1 GB of RAM (E2.1.Micro) is not enough for dnf plus the agents: without
      # swap the kernel kills dnf and cloud-init with it, and the worker never starts.
      - [ sh, -c, "test -f /swapfile || (fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab)" ]
      - dnf -y --setopt=install_weak_deps=False --disablerepo='*' --enablerepo=ol9_baseos_latest --enablerepo=ol9_appstream install podman
      - systemctl enable --now podman.socket
      - [ sh, -c, "firewall-cmd --permanent --add-port=8101-8199/tcp && firewall-cmd --reload || true" ]
      - systemctl daemon-reload
      - systemctl enable --now sbx-worker
  EOT
}

resource "oci_core_instance" "worker" {
  count               = local.use_vm ? 1 : 0
  compartment_id      = oci_identity_compartment.control.id
  availability_domain = local.worker_ads[0]
  display_name        = "${var.prefix}-worker"
  shape               = var.worker_shape
  freeform_tags       = merge(local.freeform_tags, { role = "worker" })

  dynamic "shape_config" {
    for_each = can(regex("Flex$", var.worker_shape)) ? [1] : []
    content {
      ocpus         = local.free_apps ? 2 : 1
      memory_in_gbs = local.free_apps ? 12 : 6
    }
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.worker[0].images[0].id
  }

  create_vnic_details {
    # hosting applications: a public address, and the app ports opened in network.tf
    subnet_id        = local.free_apps ? oci_core_subnet.public.id : oci_core_subnet.private.id
    display_name     = "${var.prefix}-worker"
    assign_public_ip = local.free_apps
  }

  metadata = {
    user_data = base64encode(local.worker_cloud_init)
  }

  lifecycle {
    # a newer Oracle Linux image must not replace a working worker
    ignore_changes = [source_details[0].source_id]
    precondition {
      condition     = length(local.worker_ads) > 0
      error_message = "No availability domain in this region offers ${var.worker_shape} to this tenancy. Always Free shapes exist only in the home region; install there, or set worker_shape to a shape this tenancy can launch."
    }
  }

  depends_on = [time_sleep.worker_iam]
}

resource "time_sleep" "worker_iam" {
  count           = var.enable_worker ? 1 : 0
  depends_on      = [oci_identity_policy.worker]
  create_duration = "90s"
}

output "workers" {
  value = concat(
    [for k, w in oci_container_instances_container_instance.worker : { name = k, id = w.id, state = w.state }],
    [for w in oci_core_instance.worker : { name = w.display_name, id = w.id, state = w.state }],
  )
}
