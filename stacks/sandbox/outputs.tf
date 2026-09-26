output "sandbox" {
  value = {
    id             = var.sandbox_id
    compartment_id = local.compartment_id
    owner          = var.owner
    expires        = local.expires
  }
}

output "adb" {
  value = var.enable_adb ? {
    db_name        = module.adb[0].db_name
    tier           = var.adb_tier
    connect_string = module.adb[0].connect_string
    sql_web_url    = module.adb[0].sql_web_url
    apex_url       = module.adb[0].apex_url
    id             = module.adb[0].id
    console_url    = "https://cloud.oracle.com/db/adb/${module.adb[0].id}?region=${var.region}"
  } : null
}

output "adb_admin_password" {
  value     = var.enable_adb ? module.adb[0].admin_password : null
  sensitive = true
}

output "buckets" {
  value = length(module.storage) > 0 ? module.storage[0].buckets : []
}

output "queues" {
  value = length(module.queue) > 0 ? module.queue[0].queues : []
}

# Oracle ships a console UI for each of these; without the link people never
# find them. Data Flow has Applications and Runs with the Spark UI attached,
# and Data Catalog has its own browser for harvested assets.
output "consoles" {
  value = {
    data_flow      = "https://cloud.oracle.com/data-flow/apps?region=${var.region}&compartmentId=${local.compartment_id}"
    data_catalog   = "https://cloud.oracle.com/data-catalog/data-catalogs?region=${var.region}&compartmentId=${local.compartment_id}"
    object_storage = "https://cloud.oracle.com/object-storage/buckets?region=${var.region}&compartmentId=${local.compartment_id}"
    functions      = "https://cloud.oracle.com/functions/applications?region=${var.region}&compartmentId=${local.compartment_id}"
    queues         = "https://cloud.oracle.com/queue/queues?region=${var.region}&compartmentId=${local.compartment_id}"
    nosql          = "https://cloud.oracle.com/nosql/tables?region=${var.region}&compartmentId=${local.compartment_id}"
  }
}

output "aidp" {
  value = var.enable_aidp ? merge(module.aidp[0].aidp, {
    console_url = "https://cloud.oracle.com/ai-data-platform?region=${var.region}&compartmentId=${local.compartment_id}"
  }) : null
}

output "catalog" {
  value = length(module.catalog) > 0 ? module.catalog[0].catalog : null
}

output "dataflow_jobs" {
  value = length(module.dataflow) > 0 ? module.dataflow[0].jobs : []
}

output "functions" {
  value = length(var.functions) > 0 ? [for f in module.functions[0].functions : merge(f, {
    schedule = try(local.fn_schedules[f.name].schedule, null)
  })] : []
}

output "app_instances" {
  value = [
    for k, m in module.app_extra : {
      name = k
      urls = m.urls
    }
  ]
}

output "databases" {
  description = "Every database in this sandbox: the primary one plus any extras."
  value = concat(
    var.enable_adb ? [{
      name           = "primary"
      db_name        = module.adb[0].db_name
      tier           = var.adb_tier
      connect_string = module.adb[0].connect_string
      sql_web_url    = module.adb[0].sql_web_url
      console_url    = "https://cloud.oracle.com/db/adb/${module.adb[0].id}?region=${var.region}"
    }] : [],
    [for k, m in module.adb_extra : {
      name           = k
      db_name        = m.db_name
      tier           = try([for d in var.adb_databases : d.tier if d.name == k][0], "free")
      connect_string = m.connect_string
      sql_web_url    = m.sql_web_url
      console_url    = "https://cloud.oracle.com/db/adb/${m.id}?region=${var.region}"
    }]
  )
}

output "nosql" {
  value = var.enable_nosql ? {
    tables         = module.nosql[0].tables
    table_urls     = { for n, id in module.nosql[0].table_ids : "${replace(local.name, "-", "_")}_${n}" => "https://cloud.oracle.com/nosql/tables/${id}?region=${var.region}" }
    compartment_id = local.compartment_id
  } : null
}

output "kafka" {
  value = var.enable_kafka ? {
    mode                = var.kafka_mode
    bootstrap_servers   = module.kafka[0].bootstrap_servers
    topics              = var.kafka_topics
    auth_note           = module.kafka[0].auth_note
    cluster_id          = module.kafka[0].cluster_id
    public_bootstrap    = module.kafka[0].public_bootstrap
    superuser_secret_id = module.kafka[0].superuser_secret_id
    public_cidrs        = module.kafka[0].public_cidrs
    console_url         = module.kafka[0].pool_id != null ? "https://cloud.oracle.com/storage/streaming/streampools/${module.kafka[0].pool_id}?region=${var.region}" : "https://cloud.oracle.com/kafka/clusters?region=${var.region}&compartmentId=${local.compartment_id}"
  } : null
}

output "app" {
  value = var.enable_app ? {
    url        = coalesce(module.app[0].gateway_url, try(module.app[0].urls[0], null))
    public_ip  = module.app[0].public_ip
    private_ip = module.app[0].private_ip
    urls       = module.app[0].urls
    containers = [for c in var.app_containers : c.name]
  } : null
}
