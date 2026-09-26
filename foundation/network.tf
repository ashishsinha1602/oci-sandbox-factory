# One shared VCN in sbx-control. Every sandbox stack takes the subnet OCIDs
# as inputs instead of building its own network.
#
#   public  subnet  -> internet gateway        (LBs, API Gateway, bastion)
#   private subnet  -> NAT + service gateway   (ADB, containers, OKE, Kafka)

resource "oci_core_vcn" "sandbox" {
  compartment_id = oci_identity_compartment.control.id
  display_name   = "${var.prefix}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = replace(var.prefix, "-", "")
  freeform_tags  = local.freeform_tags
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = oci_identity_compartment.control.id
  vcn_id         = oci_core_vcn.sandbox.id
  display_name   = "${var.prefix}-igw"
  enabled        = true
  freeform_tags  = local.freeform_tags
}

resource "oci_core_nat_gateway" "nat" {
  compartment_id = oci_identity_compartment.control.id
  vcn_id         = oci_core_vcn.sandbox.id
  display_name   = "${var.prefix}-nat"
  freeform_tags  = local.freeform_tags
}

data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "sgw" {
  compartment_id = oci_identity_compartment.control.id
  vcn_id         = oci_core_vcn.sandbox.id
  display_name   = "${var.prefix}-sgw"
  freeform_tags  = local.freeform_tags

  services {
    service_id = data.oci_core_services.all.services[0].id
  }
}

# --- route tables -----------------------------------------------------------

resource "oci_core_route_table" "public" {
  compartment_id = oci_identity_compartment.control.id
  vcn_id         = oci_core_vcn.sandbox.id
  display_name   = "${var.prefix}-rt-public"
  freeform_tags  = local.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = oci_identity_compartment.control.id
  vcn_id         = oci_core_vcn.sandbox.id
  display_name   = "${var.prefix}-rt-private"
  freeform_tags  = local.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat.id
  }

  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.sgw.id
  }
}

# --- security lists ---------------------------------------------------------

resource "oci_core_security_list" "public" {
  compartment_id = oci_identity_compartment.control.id
  vcn_id         = oci_core_vcn.sandbox.id
  display_name   = "${var.prefix}-sl-public"
  freeform_tags  = local.freeform_tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    source   = var.admin_cidr
    protocol = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }

  dynamic "ingress_security_rules" {
    for_each = [80, 443]
    content {
      source   = "0.0.0.0/0"
      protocol = "6"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  # ICMP path-MTU discovery
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_security_list" "private" {
  compartment_id = oci_identity_compartment.control.id
  vcn_id         = oci_core_vcn.sandbox.id
  display_name   = "${var.prefix}-sl-private"
  freeform_tags  = local.freeform_tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Anything inside the VCN may talk to the private subnet.
  # Per-sandbox isolation is done with NSGs / NetworkPolicy, not here.
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "all"
  }
}

# --- subnets ----------------------------------------------------------------

resource "oci_core_subnet" "public" {
  compartment_id             = oci_identity_compartment.control.id
  vcn_id                     = oci_core_vcn.sandbox.id
  display_name               = "${var.prefix}-public"
  cidr_block                 = var.public_subnet_cidr
  dns_label                  = "pub"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  freeform_tags              = local.freeform_tags
}

resource "oci_core_subnet" "private" {
  compartment_id             = oci_identity_compartment.control.id
  vcn_id                     = oci_core_vcn.sandbox.id
  display_name               = "${var.prefix}-private"
  cidr_block                 = var.private_subnet_cidr
  dns_label                  = "priv"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  freeform_tags              = local.freeform_tags
}
