# One sandbox = one compartment under sbx-sandboxes + whatever the requester
# switched on. Everything carries the four sbx.* tags; the reaper reads
# sbx.expires and destroys the stack after that date.

resource "time_static" "created" {}

locals {
  expires = formatdate("YYYY-MM-DD", timeadd(time_static.created.rfc3339, "${var.ttl_days * 24}h"))
  name    = "sbx-${var.sandbox_id}"

  defined_tags = {
    "${var.tag_namespace}.owner"      = var.owner
    "${var.tag_namespace}.sandbox_id" = var.sandbox_id
    "${var.tag_namespace}.team"       = var.team
    "${var.tag_namespace}.expires"    = local.expires
  }

  freeform_tags = {
    managed_by = "terraform"
    stack      = "sandbox"
    sandbox_id = var.sandbox_id
  }
}

# By default every sandbox lives in the shared sbx-sandboxes compartment
# (resources are told apart by name and by the sbx.* tags). Set
# per_sandbox_compartment = true to give each sandbox its own compartment.
resource "oci_identity_compartment" "sandbox" {
  provider       = oci.home
  count          = var.per_sandbox_compartment ? 1 : 0
  compartment_id = var.sandboxes_compartment_ocid
  name           = local.name
  description    = "Sandbox ${var.sandbox_id} for ${var.owner}. Expires ${local.expires}."
  enable_delete  = true
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags
}

# A new compartment takes a little while to become visible to every service.
resource "time_sleep" "iam_propagation" {
  depends_on      = [oci_identity_compartment.sandbox]
  create_duration = var.per_sandbox_compartment ? "60s" : "1s"
}

locals {
  compartment_id = var.per_sandbox_compartment ? oci_identity_compartment.sandbox[0].id : var.sandboxes_compartment_ocid
}

module "adb" {
  count  = var.enable_adb ? 1 : 0
  source = "./modules/adb"

  compartment_id = local.compartment_id
  name           = local.name
  tier           = var.adb_tier
  workload       = var.adb_workload
  db_version     = var.adb_version
  ecpu_count     = var.adb_ecpu_count
  storage_gb     = var.adb_storage_gb
  vcn_id         = var.vcn_id
  subnet_id      = var.private_subnet_id
  allowed_cidrs  = [var.allowed_cidr]
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

module "kafka" {
  count  = var.enable_kafka ? 1 : 0
  source = "./modules/kafka"

  compartment_id = local.compartment_id
  name           = local.name
  mode           = var.kafka_mode
  topics         = var.kafka_topics
  partitions     = var.kafka_partitions
  kafka_version  = var.kafka_version
  subnet_id      = var.private_subnet_id
  vault_id       = var.secrets_vault_id
  key_id         = var.secrets_key_id
  public_cidrs   = [var.allowed_cidr]
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

module "nosql" {
  count  = var.enable_nosql ? 1 : 0
  source = "./modules/nosql"

  compartment_id = local.compartment_id
  name           = local.name
  tables         = length(var.nosql_tables) > 0 ? var.nosql_tables : local.default_nosql_tables
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

# A sandbox asking for NoSQL with nothing specified still gets something to use.
locals {
  default_nosql_tables = [{
    name    = "events"
    ddl     = "CREATE TABLE IF NOT EXISTS {name} (id STRING, created_at TIMESTAMP(3), kind STRING, payload JSON, PRIMARY KEY (id))"
    read    = 5
    write   = 5
    storage = 1
  }]
}

# Additional databases. The first one stays module.adb so every existing output and
# injected variable keeps its meaning; these are siblings with their own credentials.
module "adb_extra" {
  for_each = { for d in var.adb_databases : d.name => d }
  source   = "./modules/adb"

  compartment_id = local.compartment_id
  name           = "${local.name}-${each.value.name}"
  tier           = each.value.tier
  workload       = each.value.workload
  db_version     = var.adb_version
  ecpu_count     = each.value.ecpu_count
  storage_gb     = each.value.storage_gb
  vcn_id         = var.vcn_id
  subnet_id      = var.private_subnet_id
  allowed_cidrs  = [var.allowed_cidr]
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

# Connection details of the other pieces are injected into every container.
locals {
  injected_env = merge(
    # The compartment is needed by anything that calls OCI from inside the
    # sandbox. DBMS_VECTOR's Generative AI provider rejects a request without it
    # ("Compartment ID must be provided"), which is how embedding failed.
    { SANDBOX_ID               = var.sandbox_id, SANDBOX_EXPIRES = local.expires,
      SANDBOX_COMPARTMENT_OCID = local.compartment_id,
      # where this sandbox runs, for any SDK call or Generative AI endpoint
    OCI_REGION = var.region },
    # the chat model the tenancy profile found answering in this region
    var.genai_model == "" ? {} : { CHAT_MODEL = var.genai_model },
    var.enable_adb ? {
      ADB_DB_NAME        = module.adb[0].db_name
      ADB_CONNECT_STRING = module.adb[0].connect_string
      ADB_ADMIN_PASSWORD = module.adb[0].admin_password
    } : {},
    var.enable_kafka ? {
      KAFKA_BOOTSTRAP_SERVERS = module.kafka[0].bootstrap_servers
    } : {},
    # Each extra database is injected as ADB_<NAME>_CONNECT_STRING / _ADMIN_PASSWORD,
    # so an app can talk to several of them at once.
    merge([for k, m in module.adb_extra : {
      "ADB_${upper(replace(k, "-", "_"))}_CONNECT_STRING" = m.connect_string
      "ADB_${upper(replace(k, "-", "_"))}_ADMIN_PASSWORD" = m.admin_password
      "ADB_${upper(replace(k, "-", "_"))}_DB_NAME"        = m.db_name
    }]...),
    # Buckets by name, so code the assistant writes (a function, a Spark job)
    # finds them: DATA_BUCKET is the first one, BUCKET_<NAME> each of them.
    length(local.bucket_names) > 0 ? merge(
      { OBJECT_NAMESPACE = module.storage[0].namespace, DATA_BUCKET = values(local.bucket_names)[0] },
      { for k, v in local.bucket_names : "BUCKET_${upper(replace(k, "-", "_"))}" => v }
    ) : {},
    var.enable_nosql ? {
      NOSQL_COMPARTMENT_OCID = local.compartment_id
      NOSQL_TABLES           = join(",", module.nosql[0].tables)
      NOSQL_REGION           = var.region
    } : {},
  )

  app_containers = [
    for c in var.app_containers : merge(c, { env = merge(local.injected_env, c.env) })
  ]
}

# Each entry is its own container instance: a separate host, so these workloads
# do not share localhost or a lifecycle with the primary app.
module "app_extra" {
  for_each = { for a in var.app_instances : a.name => a }
  source   = "./modules/app"

  compartment_id   = local.compartment_id
  name             = "${local.name}-${each.value.name}"
  vcn_id           = var.vcn_id
  subnet_id        = each.value.public ? var.public_subnet_id : var.private_subnet_id
  public           = each.value.public
  allowed_cidr     = var.allowed_cidr
  containers       = [for c in each.value.containers : merge(c, { env = merge(local.injected_env, c.env) })]
  shape            = each.value.shape
  ocpus            = each.value.ocpus
  memory_gb        = each.value.memory_gb
  gateway          = each.value.gateway
  adb_private_fqdn = var.enable_adb ? module.adb[0].private_fqdn : ""
  public_subnet_id = var.public_subnet_id
  defined_tags     = local.defined_tags
  freeform_tags    = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

module "storage" {
  count  = length(var.buckets) > 0 || length(var.dataflow_jobs) > 0 ? 1 : 0
  source = "./modules/storage"

  compartment_id = local.compartment_id
  name           = local.name
  # A Data Flow job must write its logs somewhere, so asking for one implies a bucket.
  buckets       = length(var.buckets) > 0 ? var.buckets : [{ name = "logs", public = false, tier = "Standard" }]
  defined_tags  = local.defined_tags
  freeform_tags = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

module "queue" {
  count  = length(var.queues) > 0 ? 1 : 0
  source = "./modules/queue"

  compartment_id = local.compartment_id
  name           = local.name
  queues         = var.queues
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

module "catalog" {
  count  = var.enable_catalog ? 1 : 0
  source = "./modules/catalog"

  compartment_id = local.compartment_id
  name           = local.name
  enabled        = var.enable_catalog
  data_assets    = var.catalog_assets
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

module "dataflow" {
  count  = length(var.dataflow_jobs) > 0 ? 1 : 0
  source = "./modules/dataflow"

  compartment_id  = local.compartment_id
  name            = local.name
  jobs            = var.dataflow_jobs
  logs_bucket_uri = "oci://${module.storage[0].buckets[0].name}@${module.storage[0].namespace}/"
  scripts_bucket  = module.storage[0].buckets[0].name
  namespace       = module.storage[0].namespace
  injected_env    = local.injected_env
  defined_tags    = local.defined_tags
  freeform_tags   = local.freeform_tags

  depends_on = [module.storage]
}

module "aidp" {
  count  = var.enable_aidp ? 1 : 0
  source = "./modules/aidp"

  compartment_id = local.compartment_id
  name           = local.name
  defined_tags   = local.defined_tags
  freeform_tags  = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

module "functions" {
  count  = length(var.functions) > 0 ? 1 : 0
  source = "./modules/functions"

  gateway          = var.functions_gateway
  compartment_id   = local.compartment_id
  name             = local.name
  subnet_id        = var.private_subnet_id
  public_subnet_id = var.public_subnet_id
  functions        = var.functions
  injected_env     = local.injected_env
  defined_tags     = local.defined_tags
  freeform_tags    = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}

# Functions on a schedule: the EventBridge-rule counterpart. OCI Resource
# Scheduler invokes the function on the cron given, and may do so only because
# a policy in this sandbox's compartment lets exactly these schedules manage
# its functions. Both go with the sandbox.
locals {
  # the same names modules/storage gives the buckets, known before they exist
  bucket_names = length(var.buckets) > 0 || length(var.dataflow_jobs) > 0 ? {
    for b in(length(var.buckets) > 0 ? var.buckets : [{ name = "logs" }]) : b.name => "${local.name}-${b.name}"
  } : {}
  fn_schedules = { for f in var.functions : f.name => f if try(f.schedule, "") != "" }
}

# Resource Scheduler runs a schedule at most hourly, so "every 15 minutes" is
# four hourly schedules (minutes 0, 15, 30, 45) and a minute list is one
# schedule per minute. Everything after the minute field is kept as given.
locals {
  fn_schedule_parts = merge([for name, f in local.fn_schedules : {
    for m in(
      startswith(split(" ", trimspace(f.schedule))[0], "*/")
      ? [for x in range(0, 60, tonumber(trimprefix(split(" ", trimspace(f.schedule))[0], "*/"))) : tostring(x)]
      : split(",", split(" ", trimspace(f.schedule))[0])
      ) : "${name}@${m}" => {
      fn   = name
      cron = join(" ", concat([m], slice(split(" ", trimspace(f.schedule)), 1, 5)))
    }
  }]...)
}

resource "oci_resource_scheduler_schedule" "fn" {
  for_each = length(var.functions) > 0 ? local.fn_schedule_parts : {}

  compartment_id     = local.compartment_id
  display_name       = "${local.name}-${replace(each.key, "@", "-m")}"
  description        = "Invokes function ${each.value.fn} (${each.value.cron})"
  action             = "START_RESOURCE"
  recurrence_type    = "CRON"
  recurrence_details = each.value.cron
  defined_tags       = local.defined_tags
  freeform_tags      = local.freeform_tags

  resources {
    id = one([for f in module.functions[0].functions : f.id if f.name == each.value.fn])
  }
}

resource "oci_identity_policy" "fn_schedule" {
  count    = length(oci_resource_scheduler_schedule.fn) > 0 ? 1 : 0
  provider = oci.home

  compartment_id = local.compartment_id
  name           = "${local.name}-fn-schedules"
  description    = "Lets this sandbox's schedules invoke its functions."
  statements = [for s in oci_resource_scheduler_schedule.fn :
    "allow any-user to manage functions-family in compartment id ${local.compartment_id} where all {request.principal.type = 'resourceschedule', request.principal.id = '${s.id}'}"
  ]
  defined_tags  = local.defined_tags
  freeform_tags = local.freeform_tags
}

module "app" {
  count  = var.enable_app ? 1 : 0
  source = "./modules/app"

  compartment_id   = local.compartment_id
  name             = local.name
  vcn_id           = var.vcn_id
  subnet_id        = var.app_public ? var.public_subnet_id : var.private_subnet_id
  public           = var.app_public
  allowed_cidr     = var.allowed_cidr
  containers       = local.app_containers
  shape            = var.app_shape
  ocpus            = var.app_ocpus
  memory_gb        = var.app_memory_gb
  gateway          = var.app_gateway
  adb_private_fqdn = var.enable_adb ? module.adb[0].private_fqdn : ""
  public_subnet_id = var.public_subnet_id
  defined_tags     = local.defined_tags
  freeform_tags    = local.freeform_tags

  depends_on = [time_sleep.iam_propagation]
}
