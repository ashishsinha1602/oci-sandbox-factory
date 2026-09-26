terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "compartment_id" { type = string }
variable "name" { type = string }
variable "vcn_id" { type = string }
variable "subnet_id" { type = string }
variable "public" { type = bool }
variable "allowed_cidr" { type = string }
variable "shape" { type = string }
variable "ocpus" { type = number }
variable "memory_gb" { type = number }
variable "defined_tags" { type = map(string) }
variable "freeform_tags" { type = map(string) }
variable "gateway" { type = bool }
# A paid database sits on a private endpoint: its ORDS (SQL Developer Web,
# APEX, REST) cannot be reached from a browser. When set, the gateway also
# serves /ords/* from it, so those tools open on the app's own HTTPS host.
variable "adb_private_fqdn" {
  type    = string
  default = ""
}
variable "public_subnet_id" { type = string }

variable "containers" {
  type = list(object({
    name    = string
    image   = string
    port    = optional(number)
    env     = optional(map(string), {})
    command = optional(list(string))
    args    = optional(list(string))
  }))
}

locals {
  ports = toset([for c in var.containers : tostring(c.port) if c.port != null])
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

# --- network security group: only the declared ports, only from allowed_cidr

resource "oci_core_network_security_group" "app" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-app"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "ingress" {
  for_each = local.ports

  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.allowed_cidr
  source_type               = "CIDR_BLOCK"
  description               = "App port ${each.key}"

  tcp_options {
    destination_port_range {
      min = tonumber(each.key)
      max = tonumber(each.key)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# --- the container instance -------------------------------------------------

resource "oci_container_instances_container_instance" "this" {
  compartment_id           = var.compartment_id
  availability_domain      = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name             = "${var.name}-app"
  shape                    = var.shape
  container_restart_policy = "ALWAYS"
  defined_tags             = var.defined_tags
  freeform_tags            = var.freeform_tags

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  vnics {
    subnet_id             = var.subnet_id
    display_name          = "${var.name}-app"
    is_public_ip_assigned = var.public
    nsg_ids               = [oci_core_network_security_group.app.id]
  }

  dynamic "containers" {
    for_each = var.containers
    content {
      display_name          = containers.value.name
      image_url             = containers.value.image
      environment_variables = containers.value.env
      command               = containers.value.command
      arguments             = containers.value.args
    }
  }
}

data "oci_core_vnic" "app" {
  vnic_id = oci_container_instances_container_instance.this.vnics[0].vnic_id
}

# --- API Gateway: an Oracle-provided HTTPS hostname in front of the app port
# (Container Instances themselves only get an IP address).

locals {
  # The first container's port is served at "/"; every other container with a
  # port is served under "/<container name>" on the same Oracle hostname
  # (e.g. an MCP server named "mcp" on 8765 answers at https://<host>/mcp).
  main_port = try(tostring(var.containers[0].port), null) != null ? tostring(var.containers[0].port) : (length(local.ports) > 0 ? sort(tolist(local.ports))[0] : "80")
  ip        = data.oci_core_vnic.app.private_ip_address
  backend   = "http://${local.ip}:${local.main_port}"
  extra_routes = {
    for c in slice(var.containers, 1, length(var.containers)) : c.name => c.port if c.port != null
  }
}

resource "oci_apigateway_gateway" "app" {
  count          = var.gateway ? 1 : 0
  compartment_id = var.compartment_id
  endpoint_type  = "PUBLIC"
  subnet_id      = var.public_subnet_id
  display_name   = "${var.name}-gw"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags
}

resource "oci_apigateway_deployment" "app" {
  count          = var.gateway ? 1 : 0
  compartment_id = var.compartment_id
  gateway_id     = oci_apigateway_gateway.app[0].id
  path_prefix    = "/"
  display_name   = "${var.name}-app"
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags

  specification {
    request_policies {
      cors {
        allowed_origins = ["*"]
        allowed_methods = ["*"]
        allowed_headers = ["*"]
      }
    }
    routes {
      path    = "/"
      methods = ["ANY"]
      backend {
        type                       = "HTTP_BACKEND"
        url                        = "${local.backend}/"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }
    dynamic "routes" {
      for_each = local.extra_routes
      content {
        path    = "/${routes.key}"
        methods = ["ANY"]
        backend {
          type                       = "HTTP_BACKEND"
          url                        = "http://${local.ip}:${routes.value}/${routes.key}"
          connect_timeout_in_seconds = 10
          read_timeout_in_seconds    = 300
          send_timeout_in_seconds    = 300
        }
      }
    }
    dynamic "routes" {
      for_each = local.extra_routes
      content {
        path    = "/${routes.key}/{p*}"
        methods = ["ANY"]
        backend {
          type                       = "HTTP_BACKEND"
          url                        = "http://${local.ip}:${routes.value}/${routes.key}/$${request.path[p]}"
          connect_timeout_in_seconds = 10
          read_timeout_in_seconds    = 300
          send_timeout_in_seconds    = 300
        }
      }
    }
    dynamic "routes" {
      for_each = var.adb_private_fqdn == "" ? [] : [var.adb_private_fqdn]
      content {
        path    = "/ords/{p*}"
        methods = ["ANY"]
        backend {
          type                       = "HTTP_BACKEND"
          url                        = "https://${routes.value}/ords/$${request.path[p]}"
          connect_timeout_in_seconds = 10
          read_timeout_in_seconds    = 300
          send_timeout_in_seconds    = 300
        }
      }
    }
    routes {
      path    = "/{p*}"
      methods = ["ANY"]
      backend {
        type                       = "HTTP_BACKEND"
        url                        = "${local.backend}/$${request.path[p]}"
        connect_timeout_in_seconds = 10
        read_timeout_in_seconds    = 300
        send_timeout_in_seconds    = 300
      }
    }
  }
}

output "id" {
  value = oci_container_instances_container_instance.this.id
}

output "gateway_url" {
  value = var.gateway ? "https://${oci_apigateway_gateway.app[0].hostname}" : null
}

output "public_ip" {
  value = data.oci_core_vnic.app.public_ip_address
}

output "private_ip" {
  value = data.oci_core_vnic.app.private_ip_address
}

output "urls" {
  value = concat(
    var.gateway ? ["https://${oci_apigateway_gateway.app[0].hostname}"] : [],
    [for p in local.ports : "http://${coalesce(data.oci_core_vnic.app.public_ip_address, data.oci_core_vnic.app.private_ip_address)}:${p}"],
  )
}

output "deployment_id" {
  value = try(oci_apigateway_deployment.app[0].id, null)
}
