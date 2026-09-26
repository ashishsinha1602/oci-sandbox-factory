# ---------------------------------------------------------------------------
# Set automatically by Resource Manager. Locally they come from a tfvars file.
# ---------------------------------------------------------------------------
variable "tenancy_ocid" {
  type = string
}

variable "region" {
  type = string
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment the stack itself lives in (sbx-control). Unused by resources; kept so Resource Manager can populate it."
  default     = null
}

# ---------------------------------------------------------------------------
# Foundation outputs (terraform output -json in ../../foundation)
# ---------------------------------------------------------------------------
variable "sandboxes_compartment_ocid" {
  type        = string
  description = "OCID of sbx-sandboxes. The sandbox compartment is created under it."
}

variable "vcn_id" {
  type = string
}

variable "public_subnet_id" {
  type = string
}

variable "private_subnet_id" {
  type = string
}

variable "tag_namespace" {
  type        = string
  default     = "sbx"
  description = "Defined-tag namespace created by the foundation stack."
}

# ---------------------------------------------------------------------------
# Who / what / how long
# ---------------------------------------------------------------------------
variable "sandbox_id" {
  type        = string
  description = "Short unique id, e.g. demo1 or ashish-kafka. Used in every resource name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.sandbox_id))
    error_message = "sandbox_id must be 2-20 chars, lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "owner" {
  type        = string
  description = "Requester email or principal name."
}

variable "team" {
  type    = string
  default = "personal"
}

variable "ttl_days" {
  type        = number
  default     = 3
  description = "Days until the reaper destroys this sandbox. Hard cap: 30."

  validation {
    condition     = var.ttl_days >= 1 && var.ttl_days <= 30
    error_message = "ttl_days must be between 1 and 30."
  }
}

variable "per_sandbox_compartment" {
  type        = bool
  default     = false
  description = "true = create a child compartment per sandbox (strong isolation). false = everything in sbx-sandboxes."
}

variable "allowed_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "Source CIDR allowed to reach public endpoints (app port, free-tier ADB)."
}

# ---------------------------------------------------------------------------
# ADB
# ---------------------------------------------------------------------------
variable "enable_adb" {
  type    = bool
  default = false
}

variable "adb_tier" {
  type        = string
  default     = "free"
  description = "free = Always Free (public endpoint + IP allow-list). paid = ECPU with a private endpoint in the private subnet."

  validation {
    condition     = contains(["free", "paid"], var.adb_tier)
    error_message = "adb_tier must be free or paid."
  }
}

variable "adb_workload" {
  type        = string
  default     = "OLTP"
  description = "OLTP (ATP), DW (ADW), AJD (JSON) or APEX."
}

variable "adb_ecpu_count" {
  type    = number
  default = 2
}

variable "adb_storage_gb" {
  type    = number
  default = 20
}

# ---------------------------------------------------------------------------
# Kafka
# ---------------------------------------------------------------------------
variable "enable_kafka" {
  type    = bool
  default = false
}

variable "adb_version" {
  type        = string
  default     = "23ai"
  description = "Autonomous Database version. 23ai or later is required for the VECTOR datatype."
}

variable "adb_databases" {
  description = <<-EOT
    Extra Autonomous Databases for this sandbox, beyond the first one. Each entry is a
    real database with its own ADMIN credential, not a schema. Every entry consumes a
    tenancy ADB slot, so check adb-free-count before asking for several free ones.
  EOT
  type = list(object({
    name       = string
    tier       = optional(string, "free")
    workload   = optional(string, "OLTP")
    ecpu_count = optional(number, 2)
    storage_gb = optional(number, 20)
  }))
  default = []
}

variable "enable_catalog" {
  description = "OCI Data Catalog: the metastore a Spark job resolves table names against."
  type        = bool
  default     = false
}

variable "catalog_assets" {
  description = "Sources to register in the catalog, e.g. an Object Storage bucket or a database."
  type = list(object({
    name        = string
    type_key    = string
    description = optional(string, "")
    properties  = optional(map(string), {})
  }))
  default = []
}

variable "buckets" {
  description = "Object Storage buckets. Cheap, idle-free, and outside the container core quota."
  type = list(object({
    name   = string
    public = optional(bool, false)
    tier   = optional(string, "Standard")
  }))
  default = []
}

variable "queues" {
  description = "OCI Queues: serverless point-to-point messaging, the counterpart to Kafka streams."
  type = list(object({
    name               = string
    retention_seconds  = optional(number, 3600)
    visibility_seconds = optional(number, 30)
    dead_letter_after  = optional(number, 10)
  }))
  default = []
}

variable "dataflow_jobs" {
  description = <<-EOT
    Spark applications on OCI Data Flow - the equivalent of an AWS Glue ETL job.
    Managed Spark, billed per run, nothing provisioned in between. Needs a
    bucket for logs, so ask for one in buckets as well.
  EOT
  type = list(object({
    name           = string
    file_uri       = optional(string, "")
    script         = optional(string, "")
    language       = optional(string, "PYTHON")
    spark_version  = optional(string, "3.5.0")
    driver_shape   = optional(string, "VM.Standard.E4.Flex")
    executor_shape = optional(string, "VM.Standard.E4.Flex")
    num_executors  = optional(number, 1)
    ocpus          = optional(number, 1)
    memory_gb      = optional(number, 16)
    arguments      = optional(list(string), [])
    warehouse_uri  = optional(string)
    # extra Spark settings, and Iceberg: the runtime from Maven and a catalog
    # named "lake" whose tables live in the sandbox bucket under iceberg/
    spark_conf = optional(map(string), {})
    iceberg    = optional(bool, false)
  }))
  default = []
}

variable "functions" {
  description = <<-EOT
    OCI Functions for this sandbox. Serverless, billed per invocation, so they
    cost nothing idle and do not consume the A1 core quota. Each image must
    already be in a registry the tenancy can pull from.
  EOT
  type = list(object({
    name        = string
    image       = string
    memory_mbs  = optional(number, 256)
    timeout_sec = optional(number, 30)
    env         = optional(map(string), {})
    # cron, e.g. "*/15 * * * *": OCI Resource Scheduler invokes the function
    schedule = optional(string, "")
  }))
  default = []
}

variable "app_instances" {
  description = <<-EOT
    Extra container instances beyond the first. Use these when workloads need to
    be isolated from one another - separate shapes, separate lifecycles, or
    simply not sharing a host. Containers listed inside ONE instance share a
    host and reach each other on localhost; separate instances do not.
  EOT
  type = list(object({
    name      = string
    public    = optional(bool, false)
    shape     = optional(string, "CI.Standard.A1.Flex")
    ocpus     = optional(number, 1)
    memory_gb = optional(number, 4)
    gateway   = optional(bool, true)
    containers = list(object({
      name    = string
      image   = string
      port    = optional(number)
      env     = optional(map(string), {})
      command = optional(list(string))
      args    = optional(list(string))
    }))
  }))
  default = []
}

variable "enable_nosql" {
  type    = bool
  default = false
}

variable "nosql_tables" {
  description = "NoSQL tables for this sandbox. {name} in ddl is replaced by the prefixed table name."
  type = list(object({
    name    = string
    ddl     = string
    read    = optional(number, 5)
    write   = optional(number, 5)
    storage = optional(number, 1)
  }))
  default = []
}

variable "kafka_mode" {
  type        = string
  default     = "streaming"
  description = "streaming = OCI Streaming with the Kafka-compatible endpoint (serverless, cheap). cluster = managed Kafka DEVELOPMENT cluster (real brokers, costs per hour)."

  validation {
    condition     = contains(["streaming", "cluster"], var.kafka_mode)
    error_message = "kafka_mode must be streaming or cluster."
  }
}

variable "secrets_vault_id" {
  description = "Shared Vault (in sbx-control) for per-sandbox secrets such as the Kafka superuser password. Empty = no superuser, no public Kafka endpoint."
  type        = string
  default     = ""
}
variable "secrets_key_id" {
  description = "Encryption key in secrets_vault_id."
  type        = string
  default     = ""
}
variable "enable_aidp" {
  type        = bool
  default     = false
  description = "Oracle AI Data Platform instance (lakehouse: managed Spark, Iceberg catalog, notebooks, AI) with a default workspace."
}
variable "kafka_topics" {
  type    = list(string)
  default = ["events"]
}

variable "kafka_partitions" {
  type    = number
  default = 1
}

variable "kafka_version" {
  type    = string
  default = "4.0.0"
}

# ---------------------------------------------------------------------------
# App (Container Instance, tier 1)
# ---------------------------------------------------------------------------
variable "enable_app" {
  type    = bool
  default = false
}

variable "app_containers" {
  type = list(object({
    name    = string
    image   = string
    port    = optional(number)
    env     = optional(map(string), {})
    command = optional(list(string))
    args    = optional(list(string))
  }))
  default = [{
    name  = "web"
    image = "" # no placeholder: an app with no image is a request that cannot be built
    port  = 80
  }]
  description = "Containers that share one network namespace. Ports listed here are opened to allowed_cidr."
}

variable "app_public" {
  type        = bool
  default     = true
  description = "true = public subnet with a public IP. false = private subnet only."
}

variable "functions_gateway" {
  type        = bool
  default     = true
  description = "Front every function with an API Gateway so it has a plain HTTPS URL. Off when the region's gateway limit is used up."
}

variable "app_gateway" {
  type        = bool
  default     = true
  description = "Put an API Gateway (Oracle-provided HTTPS hostname) in front of the app's main port."
}

variable "app_shape" {
  type    = string
  default = "CI.Standard.A1.Flex"
}

variable "app_ocpus" {
  type    = number
  default = 1
}

variable "app_memory_gb" {
  type    = number
  default = 4
}

variable "genai_model" {
  description = "Chat model that serves on demand in this region (from the factory's tenancy profile); injected as CHAT_MODEL. Empty = let the app choose."
  type        = string
  default     = ""
}
